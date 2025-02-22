%%%-------------------------------------------------------------------
%% @doc electricus public API
%% @end
%%%-------------------------------------------------------------------

-module(electricus_app).

-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    Port = application:get_env(electricus, port, 8080),
    Dispatch = cowboy_router:compile([{'_', [{"/:csname", electricus_ws, []}]}]),
    {ok, _} = cowboy:start_clear(ocppj, [{port, Port}], #{env => #{dispatch => Dispatch}}),
    electricus_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
