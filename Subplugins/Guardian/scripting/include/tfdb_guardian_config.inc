// tfdb_guardian_config.inc — extracted from tfdb_guardian.sp

void ParseAbilityConfig(KeyValues kv, GuardianAbility ability)
{
	kv.GetString("type", ability.Type, sizeof(ability.Type), "none");

	char buttonStr[32];
	kv.GetString("button", buttonStr, sizeof(buttonStr), "");

	if (StrEqual(buttonStr, "RELOAD", false)) ability.Button = IN_RELOAD;
	else if (StrEqual(buttonStr, "ATTACK3", false)) ability.Button = IN_ATTACK3;
	else if (StrEqual(buttonStr, "USE", false)) ability.Button = IN_USE;
	else if (StrEqual(buttonStr, "TAUNT", false)) ability.Button = 1000000;
	else ability.Button = 0;

	ability.Cooldown = kv.GetFloat("cooldown", 0.0);
	ability.Duration = kv.GetFloat("duration", 0.0);
	ability.Arg1 = kv.GetFloat("arg1", 0.0);
	ability.Arg2 = kv.GetFloat("arg2", 0.0);
	kv.GetString("particle", ability.Particle, sizeof(ability.Particle), "");
}

void ParseGuardianConfig()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/dodgeball/guardian.cfg");

	if (!FileExists(path, true))
	{
		LogError("[Guardian] Config not found: %s", path);
		return;
	}

	KeyValues kv = new KeyValues("TF2_Dodgeball");

	if (!kv.ImportFromFile(path))
	{
		LogError("[Guardian] Failed to parse: %s", path);
		delete kv;
		return;
	}

	// Shared settings
	if (kv.JumpToKey("guardian"))
	{
		enabled         = kv.GetNum("enabled", 1) != 0;
		selectionChance = kv.GetNum("selection chance", 25);
		optOutMinPlayers = kv.GetNum("opt out min players", 0);
		hudX            = kv.GetFloat("hud x", -1.0);
		hudY            = kv.GetFloat("hud y", 0.92);

		char colorStr[32];
		kv.GetString("hud color", colorStr, sizeof(colorStr), "255 50 50");

		char parts[3][8];
		ExplodeString(colorStr, " ", parts, sizeof(parts), sizeof(parts[]));
		hudColor[0] = StringToInt(parts[0]);
		hudColor[1] = StringToInt(parts[1]);
		hudColor[2] = StringToInt(parts[2]);

		kv.GoBack();
	}

	if (selectionChance < 0) selectionChance = 0;
	if (selectionChance > 100) selectionChance = 100;

	// Guardian classes
	if (kv.JumpToKey("guardian_classes"))
	{
		if (kv.GotoFirstSubKey())
		{
			do
			{
				if (guardianClassCount >= MAX_GUARDIAN_CLASSES)
				{
					LogError("[Guardian] Max classes reached (%d)", MAX_GUARDIAN_CLASSES);
					break;
				}

				int idx = guardianClassCount;

				kv.GetSectionName(guardianClasses[idx].Name, sizeof(guardianClasses[].Name));
				kv.GetString("name", guardianClasses[idx].DisplayName, sizeof(guardianClasses[].DisplayName), guardianClasses[idx].Name);

				guardianClasses[idx].Health = kv.GetNum("health", 5000);
				guardianClasses[idx].Weight = kv.GetNum("weight", 100);

				if (kv.JumpToKey("ability_1"))
				{
					ParseAbilityConfig(kv, guardianClasses[idx].PrimaryAbility);
					kv.GoBack();
				}

				if (kv.JumpToKey("ability_2"))
				{
					ParseAbilityConfig(kv, guardianClasses[idx].SecondaryAbility);
					kv.GoBack();
				}

				guardianClassCount++;
			}
			while (kv.GotoNextKey());

			kv.GoBack();
		}

		kv.GoBack();
	}

	delete kv;

	LogMessage("[Guardian] Loaded %d class(es). Enabled: %s, Chance: %d%%",
		guardianClassCount, enabled ? "yes" : "no", selectionChance);
}

int FindGuardianClassByName(const char[] className)
{
	for (int i = 0; i < guardianClassCount; i++)
	{
		if (StrEqual(guardianClasses[i].Name, className, false))
		{
			return i;
		}
	}

	return -1;
}
