%%%-------------------------------------------------------------------
%% @doc csdemo public API
%% @end
%%%-------------------------------------------------------------------

-module(voltai).

-behaviour(application).

-export([new_station/3]).
-export([start/2, stop/1]).

new_station(Name, OCPPServer, Options) ->
    station_sup:start_station(Name, OCPPServer, Options).

start(_StartType, _StartArgs) ->
    voltai_sup:start_link().

stop(_State) ->
    ok.

%% internal functions
