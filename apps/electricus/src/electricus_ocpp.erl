%%% Electricus OCPP handler
%%%
%%% Author: Will Vining <wfv@vining.dev>
%%% Copyright 2025 Will Vining
-module(electricus_ocpp).

-behaviour(ocpp_handler).

-export([init/1, handle_ocpp/3, handle_info/2]).

-record(state,
        {initialized = false :: boolean(),
         stationid :: binary(),
         pending_report :: pos_integer() | undefined}).

init(StationId) ->
    {ok, #state{stationid = StationId}}.

handle_ocpp('BootNotification', Message, State) ->
    Response =
        #{status => <<"Accepted">>,
          currentTime =>
              list_to_binary(calendar:system_time_to_rfc3339(
                                 erlang:system_time(second), [{offset, "Z"}, {unit, second}])),
          interval => application:get_env(electricus, heartbeat_interval, 3600)},
    Reply = ocpp_message:new_response('BootNotification', Response, ocpp_message:id(Message)),
    if not State#state.initialized ->
           ocpp_station:reply(State#state.stationid, Reply),
           %% I don't know what the size limit is for integers in ocpp, but 32 bits is probably safe.
           ReqId = erlang:unique_integer([positive, monotonic]) rem 16#ffffffff,
           ReportRequest =
               ocpp_message:new_request('GetBaseReport',
                                        #{reportBase => <<"FullInventory">>, requestId => ReqId}),
           case ocpp_station:call_async(State#state.stationid, ReportRequest) of
               ok ->
                   {noreply, State#state{pending_report = ReqId}};
               {error, Error} ->
                   logger:error("could not send base report request to station: ~p (~p)",
                                [State#state.stationid, Error]),
                   %% pretend everything is fine... even though it isn't. A
                   %% possible action here would be to schedule an info message
                   %% that will cause a retry a little later.
                   {noreply, State}
           end;
       true ->
           {reply, Reply, State}
    end;
handle_ocpp(_, Message, State) ->
    {error, ocpp_error:new('NotSupported', ocpp_message:id(Message)), State}.

handle_info({report_received, ReportId}, #state{pending_report = ReportId} = State) ->
    {ok, State#state{pending_report = undefined, initialized = true}};
handle_info(_, State) ->
    {ok, State}.
