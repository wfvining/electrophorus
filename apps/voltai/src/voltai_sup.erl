%%%-------------------------------------------------------------------
%% @doc csdemo top level supervisor.
%% @end
%%%-------------------------------------------------------------------

-module(voltai_sup).

-behaviour(supervisor).

-export([start_link/0, start_station/3]).

-export([init/1]).

-define(SERVER, ?MODULE).

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

start_station(Name, OCPPServer, Options) ->
    supervisor:start_child(?SERVER, [Name, OCPPServer, Options]).

init([]) ->
    SupFlags = #{
        strategy => one_for_all,
        intensity => 0,
        period => 1
    },
    ChildSpecs = [#{id => station_sup, start => {station_sup, start_link, []}},
                  #{id => client_sup, start => {client_sup, start_link, []}}],
    {ok, {SupFlags, ChildSpecs}}.

%% internal functions

