#if defined _dodgeball_profile_included
    #endinput
#endif
#define _dodgeball_profile_included

void ResetTFDBProfileCounters() {
    g_CoreProfileFrames = 0;
    g_CoreProfileRockets = 0;
}

void StopTFDBProfile() {
    float elapsed = TFDB_ProfileStop(g_CoreProfileWindow);
    LogMessage("[TFDB-PROFILE] component=core elapsed=%.3f frames=%d rockets=%d events=%d dropped=%d debug=0",
        elapsed, g_CoreProfileFrames, g_CoreProfileRockets,
        g_CoreProfileWindow.emittedEvents, g_CoreProfileWindow.droppedEvents);
}

public Action Cmd_TFDBProfile(int client, int args) {
    if (g_CoreProfileWindow.active) {
        ReplyToCommand(client, "[TFDB] Core profiling is already active.");
        return Plugin_Handled;
    }

    float duration = TFDB_ProfileDurationFromArgs(args);
    ResetTFDBProfileCounters();
    TFDB_ProfileStart(g_CoreProfileWindow, duration);
    CreateTimer(duration, Timer_StopTFDBProfile, _, TIMER_FLAG_NO_MAPCHANGE);
    ReplyToCommand(client, "[TFDB] Core profiling started for %.1f seconds.", duration);
    return Plugin_Handled;
}

public Action Timer_StopTFDBProfile(Handle timer) {
    if (g_CoreProfileWindow.active) StopTFDBProfile();
    return Plugin_Stop;
}
