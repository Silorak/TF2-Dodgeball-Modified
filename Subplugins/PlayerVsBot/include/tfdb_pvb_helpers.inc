// tfdb_pvb_helpers.inc - auto-extracted from tfdb_pvb.sp
// Do not edit directly; this is a split of the PvB plugin.

int VecToDirIndex(const float vec[3])
{
    float ang[3];
    GetVectorAngles(vec, ang);
    return WorldYawToDirIndex(ang[1]);
}

bool Normalize2D(float vec[3])
{
    float len = SquareRoot(vec[0] * vec[0] + vec[1] * vec[1]);
    if (len < 0.001) return false;
    vec[0] /= len;
    vec[1] /= len;
    return true;
}

void Perp2D(const float in_[3], float out[3])
{
    out[0] = -in_[1];
    out[1] = in_[0];
    out[2] = 0.0;
}

int PickBetterDir(int client, int desiredDir)
{
    int altDir = (desiredDir + 4) % 8;
    if (WallBlocked_[client][desiredDir] && !WallBlocked_[client][altDir])
        return altDir;
    return desiredDir;
}

void ClampAngles(float angles[3]) {
    if (angles[0] > 89.0) angles[0] = 89.0;
    else if (angles[0] < -89.0) angles[0] = -89.0;
    
    while (angles[1] > 180.0) angles[1] -= 360.0;
    while (angles[1] < -180.0) angles[1] += 360.0;
    
    angles[2] = 0.0;
}

float AimFactorForRocket(int botType, float distToRocket)
{
    float nearD = CfgAimRocketNearDist[botType];
    float farD  = CfgAimRocketFarDist[botType];
    float nearF = CfgAimRocketNear[botType];
    float farF  = CfgAimRocketFar[botType];

    if (farD <= nearD) return nearF;          // misconfigured - fail toward responsive
    if (distToRocket <= nearD) return nearF;
    if (distToRocket >= farD)  return farF;

    float t = (farD - distToRocket) / (farD - nearD);   // 0 at far, 1 at near
    return farF + (nearF - farF) * t;
}

void SmoothAim(int client, float targetAngles[3], float factor) {
    float current[3];
    GetClientEyeAngles(client, current);
    float now = GetEngineTime();

    // Detect target change for overshoot simulation
    bool targetChanged = false;
    float yawDiffTarget = targetAngles[1] - LastAimTargetYaw[client];
    if (yawDiffTarget > 180.0) yawDiffTarget -= 360.0;
    if (yawDiffTarget < -180.0) yawDiffTarget += 360.0;
    if (FloatAbs(yawDiffTarget) > 5.0 || AimTicksSinceTarget[client] == 0) {
        targetChanged = true;
        AimTicksSinceTarget[client] = 0;
    }
    AimTicksSinceTarget[client]++;
    LastAimTargetYaw[client] = targetAngles[1];

    // Overshoot: for the first 2-3 ticks after a target change, apply >1.0
    // factor so the aim overshoots then corrects back (like a real mouse flick).
    float effectiveFactor = factor;
    if (targetChanged && AimTicksSinceTarget[client] <= 3 && factor > 0.3) {
        effectiveFactor = factor * 1.15;  // 15% overshoot
    }

    // Micro-jitter: hand tremor, HELD across ticks rather than re-rolled on
    // each one. Fresh randomness every tick is white noise - at 66 tick a
    // +-0.8 degree yaw roll is ~53 degrees/second of direction changes, which
    // does not read as a steady hand, it reads as vibration. Real tremor
    // drifts. Re-roll on an interval and hold the value in between so the
    // offset moves at a human rate.
    if (now >= AimJitterUntil[client]) {
        AimJitterUntil[client] = now + GetRandomFloat(AIM_JITTER_HOLD_MIN, AIM_JITTER_HOLD_MAX);
        AimJitterYaw[client]   = GetRandomFloat(-0.8, 0.8);
        AimJitterPitch[client] = GetRandomFloat(-0.5, 0.5);
    }
    float jitterYaw = 0.0;
    float jitterPitch = 0.0;
    if (effectiveFactor > 0.1 && effectiveFactor < 1.0) {
        jitterYaw = AimJitterYaw[client];
        jitterPitch = AimJitterPitch[client];
    }

    float pitchDiff = targetAngles[0] - current[0];
    current[0] += pitchDiff * effectiveFactor + jitterPitch;

    float yawDiff = targetAngles[1] - current[1];
    if (yawDiff > 180.0) yawDiff -= 360.0;
    if (yawDiff < -180.0) yawDiff += 360.0;
    current[1] += yawDiff * effectiveFactor + jitterYaw;

    current[2] = 0.0;
    ClampAngles(current);
    TeleportEntity(client, NULL_VECTOR, current, NULL_VECTOR);

    // Hand the SMOOTHED result back to the caller.
    //
    // This is the fix for "aim spins in circles". Every call site does
    //     SmoothAim(client, aimAng, f);
    //     angles[0] = aimAng[0]; angles[1] = aimAng[1];
    // and aimAng was left holding the RAW target, so each tick set the
    // entity's angles to the smoothed value via TeleportEntity above and the
    // usercmd to the unsmoothed one. Two different angles per tick, from two
    // mechanisms, with the usercmd applied last - the smoothing was thrown
    // away and the view fought itself. Writing back means both paths carry
    // the same number, which is what makes the motion read as one hand
    // moving instead of two systems arguing.
    targetAngles[0] = current[0];
    targetAngles[1] = current[1];
    targetAngles[2] = 0.0;
}

void CalcAimAngles(const float from[3], const float to[3], float out[3]) {
    float dx = to[0] - from[0];
    float dy = to[1] - from[1];
    float dz = to[2] - from[2];
    float flatDist = SquareRoot(dx * dx + dy * dy);
    
    out[0] = 0.0 - RadToDeg(ArcTangent2(dz, flatDist));
    out[1] = RadToDeg(ArcTangent2(dy, dx));
    out[2] = 0.0;
    ClampAngles(out);
}

// Normalize an angle to [-180, 180]
float NormalizeAngle(float angle)
{
    while (angle > 180.0)  angle -= 360.0;
    while (angle < -180.0) angle += 360.0;
    return angle;
}
