%%%-------------------------------------------------------------------
%% @doc electricus public API
%% @end
%%%-------------------------------------------------------------------

-module(electricus).

-behaviour(application).

-export([start/2, stop/1]).
-export([add_station/2, add_station/4]).

start(_StartType, _StartArgs) ->
    Port = application:get_env(electricus, port, 8080),
    Dispatch = cowboy_router:compile([{'_', [{"/:csname", electricus_ws, []}]}]),
    {ok, _} = cowboy:start_clear(ocppj, [{port, Port}], #{env => #{dispatch => Dispatch}}),
    electricus_sup:start_link().

stop(_State) ->
    ok.

add_station(StationName, Password) ->
    add_station(StationName, Password, 1, []).

add_station(StationName, Password, NumEVSE, Options) ->
    true = electricus_auth:add_station(StationName, Password),
    ocpp:add_station(StationName, NumEVSE, {electricus_ocpp, {StationName, Options}}).

%% internal functions
