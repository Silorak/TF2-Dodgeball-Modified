#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>
#include <tfdb_clientcheck>

#define PLUGIN_NAME        "[TFDB] Print & replace client indexes"
#define PLUGIN_AUTHOR      "x07x08 & Silorak"
#define PLUGIN_DESCRIPTION "Does what it says"
#define PLUGIN_VERSION     "2.2.0"
#define PLUGIN_URL         "https://github.com/Silorak/TF2-Dodgeball"

char CmdBuffer[255];
char ExplodeBuffer[32][255];

Regex BracketsPattern;

public Plugin myinfo =
{
	name        = PLUGIN_NAME,
	author      = PLUGIN_AUTHOR,
	description = PLUGIN_DESCRIPTION,
	version     = PLUGIN_VERSION,
	url         = PLUGIN_URL
};

public void OnPluginStart()
{
	// No translations used by this plugin
	
	BracketsPattern = new Regex("(?<=\\[)(.*?)(?=\\])");
	
	RegAdminCmd("tf_dodgeball_print", CmdPrintMessage, ADMFLAG_CHAT, "Prints a message to chat and replaces client indexes inside a pair of '##'");
	RegAdminCmd("tf_dodgeball_print_c", CmdPrintMessageClient, ADMFLAG_CHAT, "Prints a message to a client and replaces client indexes inside a pair of '##'");
	RegAdminCmd("tf_dodgeball_phrase", CmdPrintPhrase, ADMFLAG_CHAT, "Prints a translation phrase to chat");
	RegAdminCmd("tf_dodgeball_phrase_c", CmdPrintPhraseClient, ADMFLAG_CHAT, "Prints a translation phrase to a client");
}

public void OnPluginEnd()
{
	// Release the compiled Regex handle on unload (created in OnPluginStart).
	if (BracketsPattern != null)
	{
		delete BracketsPattern;
		BracketsPattern = null;
	}
}

public Action CmdPrintMessage(int client, int cmdArgs)
{
	if (!(cmdArgs >= 1))
	{
		ReplyToCommand(client, "Usage : tf_dodgeball_print <text>");
		
		return Plugin_Handled;
	}
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer));
	TrimString(CmdBuffer);
	
	int numStrings = ExplodeString(CmdBuffer, "##", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
	int index;
	
	for (int pos = 0; pos < numStrings; pos++)
	{
		if (!ExplodeBuffer[pos][0]) continue;
		
		if ((StringToIntEx(ExplodeBuffer[pos], index) == strlen(ExplodeBuffer[pos])) &&
		    ((index >= 1) && (index <= MaxClients) && IsClientInGame(index)))
		{
			FormatEx(ExplodeBuffer[pos], sizeof(ExplodeBuffer[]), "%N", index);
		}
	}
	
	ImplodeStrings(ExplodeBuffer, numStrings, "", CmdBuffer, sizeof(CmdBuffer));
	
	CPrintToChatAll(CmdBuffer);
	
	return Plugin_Handled;
}

public Action CmdPrintMessageClient(int client, int cmdArgs)
{
	if (!(cmdArgs >= 2))
	{
		ReplyToCommand(client, "Usage : tf_dodgeball_print_c <client> <text>");
		
		return Plugin_Handled;
	}
	
	char buffer[8];
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer));
	
	int length = BreakString(CmdBuffer, buffer, sizeof(buffer));
	int target = StringToInt(buffer);
	
	TrimString(CmdBuffer[length]);
	
	int numStrings = ExplodeString(CmdBuffer[length], "##", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
	int index;
	
	for (int pos = 0; pos < numStrings; pos++)
	{
		if (!ExplodeBuffer[pos][0]) continue;
		
		if ((StringToIntEx(ExplodeBuffer[pos], index) == strlen(ExplodeBuffer[pos])) &&
		    ((index >= 1) && (index <= MaxClients) && IsClientInGame(index)))
		{
			FormatEx(ExplodeBuffer[pos], sizeof(ExplodeBuffer[]), "%N", index);
		}
	}
	
	ImplodeStrings(ExplodeBuffer, numStrings, "", CmdBuffer[length], sizeof(CmdBuffer));
	
	if ((target >= 1) && (target <= MaxClients) && IsClientInGame(target))
	{
		CPrintToChat(target, CmdBuffer[length]);
	}
	
	return Plugin_Handled;
}

public Action CmdPrintPhrase(int client, int cmdArgs)
{
	char phrase[48];
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer)); TrimString(CmdBuffer);
	
	int matches = BracketsPattern.MatchAll(CmdBuffer);
	
	if (!(matches >= 1))
	{
		ReplyToCommand(client, "Usage : tf_dodgeball_phrase <phrase> <args> (phrase and args must be surrounded by []) (phrase arguments must be separated by a comma [,])");
		
		return Plugin_Handled;
	}
	
	any aArgs[32];
	
	BracketsPattern.GetSubString(0, phrase, sizeof(phrase), 0); TrimString(phrase);
	
	if (matches == 2)
	{
		BracketsPattern.GetSubString(0, CmdBuffer, sizeof(CmdBuffer), 1);
		
		int strings = ExplodeString(CmdBuffer, ",", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
		
		for (int index = 0; index < strings; index++)
		{
			TrimString(ExplodeBuffer[index]);
			
			if ((StringToIntEx(ExplodeBuffer[index], aArgs[index]) == strlen(ExplodeBuffer[index])) ||
			    (StringToFloatEx(ExplodeBuffer[index], aArgs[index]) == strlen(ExplodeBuffer[index])))
			{
				ExplodeBuffer[index] = "\0";
			}
		}
	}
	
	PrintPhrase(phrase, ExplodeBuffer, aArgs, true);
	
	return Plugin_Handled;
}

public Action CmdPrintPhraseClient(int client, int cmdArgs)
{
	char phrase[48], targetStr[8];
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer)); TrimString(CmdBuffer);
	
	int matches = BracketsPattern.MatchAll(CmdBuffer);
	
	if (!(matches >= 2))
	{
		ReplyToCommand(client, "Usage : tf_dodgeball_phrase_c <client> <phrase> <args> (client, phrase and args must be surrounded by []) (phrase arguments must be separated by a comma [,])");
		
		return Plugin_Handled;
	}
	
	any aArgs[32];
	
	BracketsPattern.GetSubString(0, targetStr, sizeof(targetStr), 0); TrimString(targetStr);
	BracketsPattern.GetSubString(0, phrase, sizeof(phrase), 1); TrimString(phrase);
	
	int target = StringToInt(targetStr);
	
	if (matches == 3)
	{
		BracketsPattern.GetSubString(0, CmdBuffer, sizeof(CmdBuffer), 2);
		
		int strings = ExplodeString(CmdBuffer, ",", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
		
		for (int index = 0; index < strings; index++)
		{
			TrimString(ExplodeBuffer[index]);
			
			if ((StringToIntEx(ExplodeBuffer[index], aArgs[index]) == strlen(ExplodeBuffer[index])) ||
			    (StringToFloatEx(ExplodeBuffer[index], aArgs[index]) == strlen(ExplodeBuffer[index])))
			{
				ExplodeBuffer[index] = "\0";
			}
		}
	}
	
	if ((target >= 1) && (target <= MaxClients) && IsClientInGame(target))
	{
		PrintPhrase(phrase, ExplodeBuffer, aArgs, false, target);
	}
	
	return Plugin_Handled;
}

void PrintPhrase(const char[] phrase, const char args[32][255], const any aArgs[32], bool isAll, int client = -1)
{
	// Use SetGlobalTransTarget + Format with %T to properly handle
	// dynamic translation arguments without heap overflow.
	// Maximum phrase args in tfdb.phrases.txt is 5, so 8 slots is plenty.
	
	if (isAll)
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			if (!TFDB_IsRealHuman(i)) continue;
			
			char buffer[512];
			SetGlobalTransTarget(i);
			FormatEx(buffer, sizeof(buffer), "%T", phrase, i,
			         HBC(args, aArgs, 0), HBC(args, aArgs, 1),
			         HBC(args, aArgs, 2), HBC(args, aArgs, 3),
			         HBC(args, aArgs, 4), HBC(args, aArgs, 5),
			         HBC(args, aArgs, 6), HBC(args, aArgs, 7));
			
			CPrintToChat(i, buffer);
		}
	}
	else
	{
		char buffer[512];
		SetGlobalTransTarget(client);
		FormatEx(buffer, sizeof(buffer), "%T", phrase, client,
		         HBC(args, aArgs, 0), HBC(args, aArgs, 1),
		         HBC(args, aArgs, 2), HBC(args, aArgs, 3),
		         HBC(args, aArgs, 4), HBC(args, aArgs, 5),
		         HBC(args, aArgs, 6), HBC(args, aArgs, 7));
		
		CPrintToChat(client, buffer);
	}
}

// Returns either the numeric value or the string as any[].
// SM 1.12 requires any[] return type — cannot coerce char[] to any scalar.
// With only 8 calls instead of 29, this fits comfortably in default heap.
any[] HBC(const char[][] args, const any[] aArgs, int index)
{
	// Use rotating buffers so multiple HBC calls in a single FormatEx
	// each return a distinct buffer instead of overwriting each other.
	static any aResult[8][256];
	static int iBuf = 0;
	int cur = iBuf;
	iBuf = (iBuf + 1) % 8;

	if (!args[index][0])
	{
		aResult[cur][0] = aArgs[index];
		return aResult[cur];
	}

	int i;
	for (i = 0; i < 255 && args[index][i]; i++)
	{
		aResult[cur][i] = view_as<any>(args[index][i]);
	}
	aResult[cur][i] = 0;
	return aResult[cur];
}

