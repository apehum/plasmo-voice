#include <libgen.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>

extern char **environ;

// Spawns Resources/launch.sh and waits instead of exec'ing it: TCC judges a request by the code of the
// responsible process, so this signed binary has to stay alive as that process while the game runs
int main(void) {
    char exe[4096];
    uint32_t size = sizeof exe;
    if (_NSGetExecutablePath(exe, &size) != 0) return 1;

    char script[4200];
    snprintf(script, sizeof script, "%s/../Resources/launch.sh", dirname(exe));

    char *args[] = {"/bin/bash", script, NULL};
    pid_t pid;
    if (posix_spawn(&pid, "/bin/bash", NULL, NULL, args, environ) != 0) return 1;

    int status;
    if (waitpid(pid, &status, 0) < 0) return 1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
