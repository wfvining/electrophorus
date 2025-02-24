%%% Simple charging station simulator
%%%
%%% Author: Will Vining <wfv@vining.dev>
%%% Copyright 2025 Will Vining
-module(station).

-behaviour(gen_server).

-export([start_link/3, new_arrival/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, handle_continue/2]).

-type evsestate() :: empty | occupied | charging | suspended | stopped.
-type evsestatus() :: 'Available' | 'Occupied' | 'Faulted' | 'Unavailable' | 'Reserved'.

-record(evse,
        {state = empty :: evsestate(),
         status = 'Available' :: evsestatus(),
         last_event = calendar:universal_time() :: calendar:datetime(),
         event_timer :: timer:tref() | undefined,
         kwh_total = 0.0 :: float(),
         kwh_session = 0.0 :: float(),
         kw_max = 200.0 :: float(),
         kw = 0.0 :: float(),
         token :: string() | undefined,
         transaction_id :: string() | undefined}).
-record(state,
        {name :: string(),
         num_evse :: pos_integer(),
         arrival_rate :: float(),
         arrival_timer :: timer:tref() | undefined,
         queue = queue:new() :: queue:queue({float(), binary()}),
         csms :: {string(), inet:port_number()},
         client :: pid() | undefined,
         evse :: [#evse{}]}).

-spec start_link(Name :: string(),
                 OCPPServer :: {string(), inet:port_number()},
                 Options :: [Option]) ->
                    gen_server:start_ret()
              when Option :: {num_evse, pos_integer()} |
                             {password, binary()} |
                             {arrival_rate, float()}.
start_link(Name, OCPPServer, Options) ->
    NumEVSE = proplists:get_value(num_evse, Options, 1),
    ArrivalRate = proplists:get_value(arrival_rate, Options, 0.0),
    Password = proplists:get_value(password, Options, <<"">>),
    gen_server:start_link(?MODULE, {Name, NumEVSE, ArrivalRate, OCPPServer, Password}, []).

-spec new_arrival(Station :: pid(), SoC :: float(), Token :: binary()) -> ok.
new_arrival(Station, SoC, Token) ->
    gen_server:cast(Station, {arrival, SoC, Token}).

init({Name, NumEVSE, ArrivalRate, OCPPServer, Password}) ->
    process_flag(trap_exit, true),
    {ok,
     #state{name = Name,
            num_evse = NumEVSE,
            arrival_rate = ArrivalRate,
            arrival_timer = start_arrival_timer(ArrivalRate),
            evse = [#evse{} || _ <- lists:seq(1, NumEVSE)],
            csms = OCPPServer},
     {continue, {connect, Password}}}.

handle_continue({connect, Password}, State = #state{csms = {Server, Port}}) ->
    URL = uri_string:recompose(
            #{host => Server, port => Port, path => State#state.name, scheme => "http"}),
    {ok, Pid} = ocpp_client:connect(URL, State#state.name, Password),
    link(Pid),
    {ok, Message} =
        ocpp_client:send_boot_notification(
          Pid,
          'PowerUp',
          #{model => model(State), vendorName => <<"Will's Chargers">>}),
    case ocpp_message:get(<<"status">>, Message) of
        <<"Accepted">> ->
            logger:info("Station ~p (~p) accepted", [State#state.name, self()]),
            case ocpp_message:get(<<"interval">>, Message) of
                0 ->
                    Interval = 3600,
                    logger:warning(
                      "Received invalid (non-compliant) heartbeat inetrval (0). "
                      "Defaulting to 3600 seconds");
               I ->
                    Interval = I
            end,
            NewState = State#state{client = Pid},
            send_status(NewState),
            ocpp_client:send_heartbeat(Pid),
            ocpp_client:set_heartbeat_interval(Pid, Interval),
            {noreply, NewState};
        <<"Pending">> ->
            logger:error("Handling pending state not implemented. Exiting."),
            {stop, normal};
        <<"Rejected">> ->
            logger:error("Station rejected by CSMS."),
            {stop, normal}
    end;
handle_continue(check_queue, State = #state{queue = Q}) ->
    ChargerAvailable = charger_available(State#state.evse),
    case queue:out(Q) of
        {{value, {SoC, Token}}, Q1} when ChargerAvailable ->
            {noreply, start_session(State#state{queue = Q1}, SoC, Token)};
        _ ->
            {noreply, State}
    end.

handle_call(_, _From, State) ->
    {noreply, State}.

handle_cast({arrival, SoC, Token}, State) ->
    {noreply, State#state{queue = queue:in({SoC, Token}, State#state.queue)},
     {continue, check_queue}}.

handle_info({ocpp, {call, Message}}, State) ->
    case ocpp_message:request_type(Message) of
        'GetBaseReport' ->
            MessageId = ocpp_message:id(Message),
            case ocpp_message:get(<<"reportBase">>, Message) of
                <<"FullInventory">> ->
                    ocpp_client:rpcreply(
                      State#state.client, MessageId, 'GetBaseReport', #{status => <<"Accepted">>}),
                    RequestId = ocpp_message:get(<<"requestId">>, Message),
                    send_base_report('FullInventory', RequestId, State);
                _ ->
                    ocpp_client:rpcreply(
                      State#state.client, MessageId, 'GetBaseReport', #{status => <<"NotSupported">>})
            end;
        Type ->
            logger:warning("unhandled message type: ~p ~p", [Type, Message]),
            ok
    end,
    {noreply, State};
handle_info({arrival, SoC, Token}, State) ->
    new_arrival(self(), SoC, Token),
    {noreply, State#state{arrival_timer = start_arrival_timer(State#state.arrival_rate)}}.

send_base_report('FullInventory', RequestId, State) ->
    %% XXX: This is not complete per the requirements of the standard (B07.FR.08)
    Time = list_to_binary(calendar:system_time_to_rfc3339(
                            erlang:system_time(second), [{offset, "Z"}, {unit, second}])),
    Data = [#{component => #{name => <<"EVSE">>, evse => #{id => N}},
              variable => #{name => <<"AvailabilityState">>},
              variableAttribute => [#{value => atom_to_binary(EVSE#evse.status)}]}
            || {N, EVSE} <- lists:zip(lists:seq(1, State#state.num_evse), State#state.evse)],
    Payload = #{requestId => RequestId,
                generatedAt => Time,
                reportData => Data,
                seqNo => 0},
    Response = ocpp_client:send_report(State#state.client, Payload),
    logger:info("Server response to report: ~p", [Response]).

send_status(State) ->
    lists:foreach(
      fun({N, EVSE}) ->
              ocpp_client:send_status_notification(State#state.client, N, 1, EVSE#evse.status)
      end,
      lists:zip(lists:seq(1, State#state.num_evse), State#state.evse)).

charger_available(EVSEs) ->
    lists:any(fun(EVSE) -> EVSE#evse.state =:= empty end, EVSEs).

start_session(State, SoC, Token) ->
    %% 1. Select EVSE
    {ok, EVSEId} = select_evse(State#state.evse),
    %% 2. Send AuthorizeRequest
    case ocpp_client:send_authorize_request(State#state.client, Token) of
        {ok, AuthorizeResponse} ->
            %% 3. Check if Accepted
            case ocpp_message:get(<<"idTokenInfo/status">>, AuthorizeResponse) of
                <<"Accepted">> ->
                    logger:info("Session authorized at EVSE ~p", [EVSEId]),
                    %% 4. Send StartTransaction
                    start_transaction(State, EVSEId, SoC, Token);
                Status ->
                    logger:warning("Session authorization failed: ~p", [Status]),
                    State
            end;
        {error, {ocpp, Reason, _, Details}} ->
            logger:error("AuthorizeRequest failed: ~p (~p)", [Reason, Details]),
            State
    end.

start_transaction(State, EVSEId, SoC, Token) ->
    TransactionId = identifier_string(),
    case ocpp_client:start_transaction(
           State#state.client,
           <<"Authorized">>,
           TransactionId,
           Token,
           EVSEId)
    of
        {ok, TransactionResponse} ->
            case ocpp_message:get(<<"idTokenInfo/status">>, TransactionResponse) of
                <<"Accepted">> ->
                    %% 5. Update state of the EVSE
                    %%    - schedule stop charging
                    logger:info("Transaction started at EVSE ~p", [EVSEId]),
                    start_charging(State, EVSEId, SoC, Token, TransactionId);
                Status ->
                    logger:warning("Transaction at EVSE ~p not allowed: ~p", [EVSEId, Status]),
                    State
            end;
        {error, {ocpp, Reason, _, Details}} ->
            logger:error("TransactionRequest failed: ~p (~p)", [Reason, Details]),
            State
    end.

start_charging(State, EVSEId, SoC, Token, TransactionId) ->
    maybe
        %% 6. Send status notification for EVSE
        {ok, _} ?= ocpp_client:send_status_notification(State#state.client, EVSEId, 1, <<"Occupied">>),
        %% 7. Send transaction update with triggerReason = CablePluggedIn, chargingState = EVConnected
        {ok, TxResponse} ?=
            ocpp_client:update_transaction(
              State#state.client, <<"CablePluggedIn">>, TransactionId, Token, EVSEId,
              [{charging_state, <<"EVConnected">>}]),
        <<"Accepted">> ?= ocpp_message:get(<<"idTokenInfo/status">>, TxResponse),
        %% 8. Send transaction update with triggerReason = ChargingStateChanged, chargingState = Charging
        {ok, TxResponse1} ?=
            ocpp_client:update_transaction(
              State#state.client, <<"ChargingStateChanged">>, TransactionId, Token, EVSEId,
              [{charging_state, <<"Charging">>}]),
        <<"Accepted">> ?= ocpp_message:get(<<"idTokenInfo/status">>, TxResponse1),
        %% 9. Schedule charging end
        %% 10. Update EVSE list and return updated State
        set_charging_state(State, EVSEId, SoC, Token, TransactionId)
    else
        Reason ->
            logger:error("Start charging failed ~p", Reason),
            State
    end.

set_charging_state(State, EVSEId, SoC, Token, TransactionId) ->
    {First, [EVSE|Rest]} = lists:split(EVSEId - 1, State#state.evse),
    KWhNeeded = 130.0 - (130.0 * SoC),
    Duration = round(3600_000.0 * KWhNeeded / EVSE#evse.kw_max),
    io:format("kWh Needed: ~p, Duration: ~p", [KWhNeeded, Duration]),
    NewEVSEList =
        First ++ [EVSE#evse{
                    kw = EVSE#evse.kw_max,
                    kwh_session = 0.0,
                    token = Token,
                    last_event = calendar:universal_time(),
                    transaction_id = TransactionId,
                    event_timer = timer:send_after(Duration, {charging_done, EVSEId})}
                 | Rest],
    State#state{evse = NewEVSEList}.

select_evse(EVSEs) ->
    case lists:search(fun({_, EVSE}) -> EVSE#evse.state =:= empty end,
                      lists:zip(lists:seq(1, length(EVSEs)), EVSEs))
    of
        {value, {N, _EVSE}} ->
            {ok, N};
        false ->
            {error, none_available}
    end.

model(#state{arrival_rate = ArrivalRate}) when ArrivalRate > 0.0 ->
    <<"Poisson">>;
model(_) ->
    <<"Manual">>.

start_arrival_timer(ArrivalRate) when ArrivalRate == 0.0 ->
    undefined;
start_arrival_timer(ArrivalRate) when ArrivalRate > 0.0 ->
    T = exponential(ArrivalRate),
    SoC = min(0.99, max(0.01, rand:normal(0.25, 0.25))),
    %% This should probably be a uuid, but I don't really care about
    %% collisions (which are unlikely at the scale of a demo anyway)
    Token = identifier_string(),
    timer:send_after(timer:seconds(T), {arrival, SoC, Token}).

identifier_string() ->
    << <<($! + B rem ($~ - $!)):8>> || <<B:8>> <= rand:bytes(36) >>.

exponential(Rate) ->
    U = rand:uniform_real(),
    -math:log(U) / Rate.
