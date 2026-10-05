/* SPDX-License-Identifier: GPL-2.0-or-later */
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <unistd.h>
#include <lua.h>
#include <lauxlib.h>

/* procd signals its direct child when stopping an instance. Workers must
 * also disappear if that supervisor exits or is killed during a restart. */
static int app_fork(lua_State *L)
{
	pid_t parent = getpid();
	pid_t pid = fork();
	if (pid < 0) {
		lua_pushnil(L);
		lua_pushstring(L, strerror(errno));
		return 2;
	}
	if (pid == 0) {
		if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent)
			_exit(1);
	}
	lua_pushinteger(L, pid);
	return 1;
}

int luaopen_c2000max_app_process(lua_State *L)
{
	static const luaL_Reg methods[] = {
		{ "fork", app_fork },
		{ NULL, NULL }
	};
	lua_newtable(L);
	luaL_register(L, NULL, methods);
	return 1;
}
