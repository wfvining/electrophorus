%%% Electricus websocket handler
%%%
%%% Author: Will Vining <wfv@vining.dev>
%%% Copyright 2025 Will Vining
-module(electricus_ws).

-behaviour(cowboy_websocket).

-export([init/2, websocket_init/1, websocket_handle/2, websocket_info/2]).

-record(state, {station :: binary(),
                pending_call :: undefined | {binary(), ocpp_message:messagetype()}}).

init(Req, State) ->
    StationName = cowboy_req:binding(csname, Req),
    case cowboy_req:parse_header(<<"authorization">>, Req) of
        {basic, StationName, Password} ->
            case electricus_auth:authenticate(StationName, Password) of
                true ->
                    init_authenticated(StationName, Req, State);
                false ->
                    {ok, cowboy_req:reply(401, Req), State};
                error ->
                    {ok, cowboy_req:reply(404, Req), State}
            end;             
        _ ->
            {ok, cowboy_req:reply(401, Req), State}
    end.

init_authenticated(StationName, Req, State) ->
    case cowboy_req:parse_header(<<"sec-websocket-protocol">>, Req) of
        undefined ->
            {ok, cowboy_req:reply(400, Req), State};
        Subprotocols ->
            case lists:member(<<"ocpp2.0.1">>, Subprotocols) of
                true ->
                    %% XXX Setting the accepted protocol causes cowboy to immediately
                    %%     close the connection after the websocket upgrade completes.
                    %%
                    %% Req1 = cowboy_req:set_resp_header(<<"sec-websocket-protocol">>, <<"ocpp2.0.1">>, Req),
                    Req1 = Req,
                    {cowboy_websocket, Req1, #state{station = StationName}, #{compress => true}};
                false ->
                    {cowboy_websocket, Req, close, #{compress => true}}
            end
    end.

websocket_init(close) ->
    {[close], close};
websocket_init(State) ->
    case ocpp_station:connect(State#state.station) of
        ok ->
            {[], State};
        _ ->
            %% there isn't a clear way to indicate an error other than
            %% closing the connection
            {[close], State}
    end.

websocket_handle({text, Msg}, #state{pending_call = PendingCall} = State) ->
    case ocpp_rpc:decode(Msg) of
        {ok, {call, _MessageId, Message}} ->
            ocpp_station:rpccall(State#state.station, Message),
            {[], State};
        {ok, {callresult, MessageId, Payload}} when element(1, PendingCall) =:= MessageId ->
            try
                Response = ocpp_message:new_response(element(2, PendingCall), Payload, MessageId),
                ocpp_station:rpcreply(State#state.station, Response)
            catch _:_ ->
                    ok
            end,
            {[], State#state{pending_call = undefined}};
        {ok, {callresult, _, _}} ->
            %% doesn't have the correct message id - drop it.
            {[], State};
        {ok, {callerror, _MessageId, Message}} ->
            ocpp_station:rpcerror(State, Message),
            {[], State};
        {error, _Error} ->
            %% "When a message contains any invalid OCPP and/or it is
            %% not conform the JSON schema, the system is allowed to
            %% drop the message."
            {[], State}
    end;
websocket_handle(ping, State) ->
    %% Cowboy automatically sends pongs, this message is just informational
    {[], State}.

websocket_info({ocpp, {rpccall, Message}}, State) ->
    {[{text, ocpp_rpc:encode_call(Message)}],
     State#state{pending_call = {ocpp_message:id(Message),
                                 ocpp_message:request_type(Message)}}};
websocket_info({ocpp, {rpcerror, Message}}, State) ->
    Error = ocpp_rpc:encode_callerror(Message),
    {[{text, Error}], State};
websocket_info({ocpp, {rpcreply, Message}}, State) ->
    Reply = ocpp_rpc:encode_callresult(Message),
    {[{text, Reply}], State}.
