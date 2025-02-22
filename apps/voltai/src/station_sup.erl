%%%-------------------------------------------------------------------
%% @doc csdemo top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(station_sup).

-behaviour(supervisor).

-export([start_link/0, start_station/3]).
-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_station(Name :: string(),
                    OCPPServer :: {string(), inet:port_number()},
                    Options :: [Option]) ->
                       gen_server:start_ret()
    when Option :: {num_evse, pos_integer()} | {password, binary()} | {arrival_rate, float()}.
start_station(Name, OCPPServer, Options) ->
    supervisor:start_child(?SERVER, [Name, OCPPServer, Options]).

init([]) ->
    SupFlags =
        #{strategy => simple_one_for_one,
          intensity => 0,
          period => 1},
    ChildSpecs = [#{id => station, start => {station, start_link, []}}],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions
