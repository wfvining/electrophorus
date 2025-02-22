%%% Simple OCPP client
%%%
%%% Author: Will Vining <wfv@vining.dev>
%%% Copyright 2025 Will Vining
-module(ocpp_client).

-behavior(gen_statem).

-export([start_link/4, connect/3, send_boot_notification/3, send_status_notification/4,
         send_heartbeat/1, rpcreply/4, send_report/2]).
-export([callback_mode/0, init/1]).
-export([disconnected/3, upgrade/3, connected/3]).

-record(state,
        {conn :: pid(),
         ws :: reference(),
         station :: pid(),
         username :: binary(),
         password :: binary(),
         pending = [] :: [{binary(), atom(), gen_statem:from()}],
         ping_timer :: timer:tref(),
         path :: string()}).

start_link(URL, UserName, Password, StationPid) ->
    gen_statem:start_link(?MODULE, {URL, UserName, Password, StationPid}, []).

connect(URL, UserName, Password) ->
    client_sup:start_client(URL, UserName, Password, self()).

send_heartbeat(Conn) ->
    gen_statem:call(Conn, send_heartbeat).

send_boot_notification(Conn, Reason, Station) ->
    gen_statem:call(Conn, {send_boot, Reason, Station}).

send_status_notification(Conn, EVSEId, ConnectorId, Status) ->
    Time =
        list_to_binary(calendar:system_time_to_rfc3339(
                           erlang:system_time(second), [{offset, "Z"}, {unit, second}])),
    gen_statem:call(Conn, {send_status, EVSEId, ConnectorId, Status, Time}).

send_report(Conn, Payload) ->
    gen_statem:call(Conn, {send_report, Payload}).

rpcreply(Conn, MessageId, Type, Payload) ->
    gen_statem:cast(Conn, {rpcreply, MessageId, Type, Payload}).

init({URL, UserName, Password, StationPid}) ->
    {ok,
     disconnected,
     #state{station = StationPid,
            username = UserName,
            password = Password},
     [{next_event, internal, {connect, URL}}]}.

callback_mode() ->
    state_functions.

disconnected(state_timeout, connect_failed, _State) ->
    {stop, connect_failed};
disconnected(info,
             {gun_up, _ConnPid, _},
             #state{username = UserName, password = Password} = State) ->
    Credentials = base64:encode(<<UserName/binary, ":", Password/binary>>),
    WSRef =
        gun:ws_upgrade(State#state.conn,
                       State#state.path,
                       [{<<"sec-websocket-protocol">>, <<"ocpp2.0.1">>},
                        {<<"authorization">>, <<"Basic ", Credentials/binary>>}]),
    {next_state, upgrade, State#state{ws = WSRef}, [{state_timeout, 5000, upgrade_failed}]};
disconnected(internal, {connect, URL}, State) ->
    URIMap = uri_string:parse(URL),
    Host = maps:get(host, URIMap),
    Port = maps:get(port, URIMap, 80),
    Path = maps:get(path, URIMap, "/"),
    {ok, Conn} = gun:open(Host, Port),
    {keep_state,
     State#state{conn = Conn, path = Path},
     [{state_timeout, 5000, connect_failed}]};
disconnected(_, _, _) ->
    {keep_state_and_data, [postpone]}.

upgrade(state_timeout, upgrade_failed, _State) ->
    {stop, upgrade_failed};
upgrade(info, {gun_upgrade, _, _, [<<"websocket">>], _}, State) ->
    {ok, Timer} =
        timer:apply_interval(20000, gun, ws_send, [State#state.conn, State#state.ws, ping]),
    {next_state, connected, State#state{ping_timer = Timer}};
upgrade(info, Message, _State) ->
    io:format("got message: ~p", [Message]),
    {stop, normal};
upgrade(_, _, _) ->
    {keep_state_and_data, [postpone]}.

connected({call, From}, {send_boot, Reason, Station}, State) ->
    Msg = ocpp_message:new_request('BootNotification',
                                   [{"chargingStation", Station}, {"reason", Reason}]),
    RPCCall = ocpp_rpc:encode_call(Msg),
    ok = gun:ws_send(State#state.conn, State#state.ws, [{text, RPCCall}]),
    {keep_state,
     State#state{pending =
                     [{ocpp_message:id(Msg), 'BootNotification', From} | State#state.pending]}};
connected({call, From}, {send_status, EVSEId, ConnectorId, Status, Time}, State) ->
    Msg = ocpp_message:new_request('StatusNotification',
                                   #{timestamp => Time,
                                     connectorStatus => Status,
                                     evseId => EVSEId,
                                     connectorId => ConnectorId}),
    RPCCall = ocpp_rpc:encode_call(Msg),
    ok = gun:ws_send(State#state.conn, State#state.ws, [{text, RPCCall}]),
    {keep_state,
     State#state{pending =
                     [{ocpp_message:id(Msg), 'StatusNotification', From} | State#state.pending]}};
connected({call, From}, {send_report, Payload}, State) ->
    Msg = ocpp_message:new_request('NotifyReport', Payload),
    RPCCall = ocpp_rpc:encode_call(Msg),
    ok = gun:ws_send(State#state.conn, State#state.ws, [{text, RPCCall}]),
    {keep_state, 
     State#state{pending = [{ocpp_message:id(Msg), 'StatusNotification', From} | State#state.pending]}};
connected({call, From}, send_heartbeat, State) ->
    Msg = ocpp_message:new_request('Heartbeat', #{}),
    RPCCall = ocpp_rpc:encode_call(Msg),
    ok = gun:ws_send(State#state.conn, State#state.ws, [{text, RPCCall}]),
    {keep_state,
     State#state{pending = [{ocpp_message:id(Msg), 'Heartbeat', From} | State#state.pending]}};
connected(cast, {rpcreply, MessageId, Type, Payload}, State) ->
    Msg = ocpp_message:new_response(Type, Payload, MessageId),
    RPCCall = ocpp_rpc:encode_callresult(Msg),
    gun:ws_send(State#state.conn, State#state.ws, [{text, RPCCall}]),
    {keep_state, State};
connected(info, {gun_down, _, _, _, _, _}, _State) ->
    {stop, connection_down};
connected(info, {gun_ws, _, _, {close, _}}, State) ->
    State#state.station ! {ocpp, closed},
    {stop, normal};
connected(info, {gun_ws, _, _, {text, Msg}}, State) ->
    case ocpp_rpc:decode(Msg) of
        {ok, {callresult, MessageId, Message}} ->
            case lists:keytake(MessageId, 1, State#state.pending) of
                {value, {_, Type, From}, Pending} ->
                    gen_statem:reply(From,
                                     {ok, ocpp_message:new_response(Type, Message, MessageId)}),
                    {keep_state, State#state{pending = Pending}};
                false ->
                    logger:warning("Got unexpected OCPP CALLRESULT message for ~p: ~p ~p",
                                   [State#state.station, MessageId, Message]),
                    keep_state_and_data
            end;
        {ok, {call, _MessageId, Message}} ->
            State#state.station ! {ocpp, {call, Message}},
            keep_state_and_data;
        {ok, {callerror, Error}} ->
            MessageId = ocpp_error:id(Error),
            Reason = ocpp_error:type(Error),
            Description = ocpp_error:description(Error),
            Details = ocpp_error:details(Error),
            case lists:keytake(MessageId, 1, State#state.pending) of
                {value, {_, From}, Pending} ->
                    gen_statem:reply(From, {error, {ocpp, Reason, Description, Details}}),
                    {keep_state, State#state{pending = Pending}};
                false ->
                    logger:warning("Got unexpected OCPP CALLERROR message for ~p: ~p ~p ~p ~p",
                                   [State#state.station, MessageId, Reason, Description, Details]),
                    keep_state_and_data
            end
    end.
