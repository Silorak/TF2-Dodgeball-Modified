#if defined _tfdb_profiling_included
    #endinput
#endif
#define _tfdb_profiling_included

#include <profiler>

#define TFDB_PROFILE_DEFAULT_DURATION 15.0
#define TFDB_PROFILE_MAX_DURATION 30.0
#define TFDB_PROFILE_EVENT_BUDGET 100000

enum struct TFDBProfileWindow {
    bool active;
    bool emitEvents;
    int eventsRemaining;
    int emittedEvents;
    int droppedEvents;
    float startedAt;
    float duration;
}

stock void TFDB_MarkProfilerNativesOptional() {
    MarkNativeAsOptional("IsProfilingActive");
    MarkNativeAsOptional("EnterProfilingEvent");
    MarkNativeAsOptional("LeaveProfilingEvent");
}

stock float TFDB_ProfileClampDuration(float duration) {
    if (duration < 1.0) return 1.0;
    if (duration > TFDB_PROFILE_MAX_DURATION) return TFDB_PROFILE_MAX_DURATION;
    return duration;
}

stock float TFDB_ProfileDurationFromArgs(int args) {
    if (args < 1) return TFDB_PROFILE_DEFAULT_DURATION;
    char value[16];
    GetCmdArg(1, value, sizeof(value));
    return TFDB_ProfileClampDuration(StringToFloat(value));
}

stock bool TFDB_ProfileEventsAvailable() {
    if (!CanTestFeatures()) return false;
    if (GetFeatureStatus(FeatureType_Native, "IsProfilingActive") != FeatureStatus_Available) return false;
    if (GetFeatureStatus(FeatureType_Native, "EnterProfilingEvent") != FeatureStatus_Available) return false;
    if (GetFeatureStatus(FeatureType_Native, "LeaveProfilingEvent") != FeatureStatus_Available) return false;
    return IsProfilingActive();
}

stock void TFDB_ProfileStart(TFDBProfileWindow window, float duration) {
    window.active = true;
    window.emitEvents = TFDB_ProfileEventsAvailable();
    window.eventsRemaining = TFDB_PROFILE_EVENT_BUDGET;
    window.emittedEvents = 0;
    window.droppedEvents = 0;
    window.startedAt = GetEngineTime();
    window.duration = TFDB_ProfileClampDuration(duration);
}

stock bool TFDB_ProfileTakeEvent(TFDBProfileWindow window) {
    if (window.eventsRemaining <= 0) {
        window.droppedEvents++;
        return false;
    }
    window.eventsRemaining--;
    if (!window.emitEvents) return false;
    window.emittedEvents++;
    return true;
}

stock float TFDB_ProfileStop(TFDBProfileWindow window) {
    float elapsed = GetEngineTime() - window.startedAt;
    window.active = false;
    window.emitEvents = false;
    return elapsed;
}
