%%% Basic (not persistent or particularly secure) authentication.
%%%
%%% Author: Will Vining <wfv@vining.dev>
%%% Copyright 2025 Will Vining

-module(electricus_auth).

-behavior(gen_server).

-export([start_link/0, authenticate/2, add_station/2]).
-export([init/1, handle_call/3, handle_cast/2]).

-define(SERVER, ?MODULE).

start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

add_station(Name, Password) ->
    gen_server:call(?SERVER, {add_station, Name, Password}).

authenticate(Name, Password) ->
    gen_server:call(?SERVER, {authenticate, Name, Password}).

init([]) ->
    Tab = ets:new(?MODULE, [set, private]),
    {ok, Tab}.

handle_call({authenticate, Name, Password}, _From, Tab) ->
    case ets:lookup(Tab, Name) of 
        [] -> {reply, error, Tab};
        [{Name, Salt, Hash}] ->
            H = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
            {reply, H =:= Hash, Tab}
    end;
handle_call({add_station, Name, Password}, _From, Tab) ->
    Salt = crypto:strong_rand_bytes(8),
    Hash = crypto:hash(sha256, <<Salt/binary, Password/binary>>),
    {reply, ets:insert_new(Tab, {Name, Salt, Hash}), Tab}.

handle_cast(_, Tab) ->
    {noreply, Tab}.
