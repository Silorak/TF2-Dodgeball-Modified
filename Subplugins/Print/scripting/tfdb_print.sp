#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <multicolors>

#define PLUGIN_NAME        "[TFDB] Print & replace client indexes"
#define PLUGIN_AUTHOR      "x07x08"
#define PLUGIN_DESCRIPTION "Does what it says"
#define PLUGIN_VERSION     "1.1.2"
#define PLUGIN_URL         "https://github.com/x07x08/TF2-Dodgeball-Modified"

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
	LoadTranslations("tfdb.phrases.txt");
	
	BracketsPattern = new Regex("(?<=\\[)(.*?)(?=\\])");
	
	RegAdminCmd("tf_dodgeball_print", CmdPrintMessage, ADMFLAG_CHAT, "Prints a message to chat and replaces client indexes inside a pair of '##'");
	RegAdminCmd("tf_dodgeball_print_c", CmdPrintMessageClient, ADMFLAG_CHAT, "Prints a message to a client and replaces client indexes inside a pair of '##'");
	RegAdminCmd("tf_dodgeball_phrase", CmdPrintPhrase, ADMFLAG_CHAT, "Prints a translation phrase to chat");
	RegAdminCmd("tf_dodgeball_phrase_c", CmdPrintPhraseClient, ADMFLAG_CHAT, "Prints a translation phrase to a client");
}

public Action CmdPrintMessage(int iClient, int iArgs)
{
	if (!(iArgs >= 1))
	{
		ReplyToCommand(iClient, "Usage : tf_dodgeball_print <text>");
		
		return Plugin_Handled;
	}
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer));
	TrimString(CmdBuffer);
	
	int iNumStrings = ExplodeString(CmdBuffer, "##", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
	int iIndex;
	
	for (int iPos = 0; iPos < iNumStrings; iPos++)
	{
		if (!ExplodeBuffer[iPos][0]) continue;
		
		if ((StringToIntEx(ExplodeBuffer[iPos], iIndex) == strlen(ExplodeBuffer[iPos])) &&
		    ((iIndex >= 1) && (iIndex <= MaxClients) && IsClientInGame(iIndex)))
		{
			FormatEx(ExplodeBuffer[iPos], sizeof(ExplodeBuffer[]), "%N", iIndex);
		}
	}
	
	ImplodeStrings(ExplodeBuffer, iNumStrings, "", CmdBuffer, sizeof(CmdBuffer));
	
	CPrintToChatAll(CmdBuffer);
	
	return Plugin_Handled;
}

public Action CmdPrintMessageClient(int iClient, int iArgs)
{
	if (!(iArgs >= 2))
	{
		ReplyToCommand(iClient, "Usage : tf_dodgeball_print_c <client> <text>");
		
		return Plugin_Handled;
	}
	
	char strBuffer[8];
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer));
	
	int iLength = BreakString(CmdBuffer, strBuffer, sizeof(strBuffer));
	int iTarget = StringToInt(strBuffer);
	
	TrimString(CmdBuffer[iLength]);
	
	int iNumStrings = ExplodeString(CmdBuffer[iLength], "##", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
	int iIndex;
	
	for (int iPos = 0; iPos < iNumStrings; iPos++)
	{
		if (!ExplodeBuffer[iPos][0]) continue;
		
		if ((StringToIntEx(ExplodeBuffer[iPos], iIndex) == strlen(ExplodeBuffer[iPos])) &&
		    ((iIndex >= 1) && (iIndex <= MaxClients) && IsClientInGame(iIndex)))
		{
			FormatEx(ExplodeBuffer[iPos], sizeof(ExplodeBuffer[]), "%N", iIndex);
		}
	}
	
	ImplodeStrings(ExplodeBuffer, iNumStrings, "", CmdBuffer[iLength], sizeof(CmdBuffer));
	
	if ((iTarget >= 1) && (iTarget <= MaxClients) && IsClientInGame(iTarget))
	{
		CPrintToChat(iTarget, CmdBuffer[iLength]);
	}
	
	return Plugin_Handled;
}

public Action CmdPrintPhrase(int iClient, int iArgs)
{
	char strPhrase[48];
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer)); TrimString(CmdBuffer);
	
	int iMatches = BracketsPattern.MatchAll(CmdBuffer);
	
	if (!(iMatches >= 1))
	{
		ReplyToCommand(iClient, "Usage : tf_dodgeball_phrase <phrase> <args> (phrase and args must be surrounded by []) (phrase arguments must be separated by a comma [,])");
		
		return Plugin_Handled;
	}
	
	any aArgs[32];
	
	BracketsPattern.GetSubString(0, strPhrase, sizeof(strPhrase), 0); TrimString(strPhrase);
	
	if (iMatches == 2)
	{
		BracketsPattern.GetSubString(0, CmdBuffer, sizeof(CmdBuffer), 1);
		
		int iStrings = ExplodeString(CmdBuffer, ",", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
		
		for (int iIndex = 0; iIndex < iStrings; iIndex++)
		{
			TrimString(ExplodeBuffer[iIndex]);
			
			if ((StringToIntEx(ExplodeBuffer[iIndex], aArgs[iIndex]) == strlen(ExplodeBuffer[iIndex])) ||
			    (StringToFloatEx(ExplodeBuffer[iIndex], aArgs[iIndex]) == strlen(ExplodeBuffer[iIndex])))
			{
				ExplodeBuffer[iIndex] = "\0";
			}
		}
	}
	
	PrintPhrase(strPhrase, ExplodeBuffer, aArgs, true);
	
	return Plugin_Handled;
}

public Action CmdPrintPhraseClient(int iClient, int iArgs)
{
	char strPhrase[48], strTarget[8];
	
	GetCmdArgString(CmdBuffer, sizeof(CmdBuffer)); TrimString(CmdBuffer);
	
	int iMatches = BracketsPattern.MatchAll(CmdBuffer);
	
	if (!(iMatches >= 2))
	{
		ReplyToCommand(iClient, "Usage : tf_dodgeball_phrase_c <client> <phrase> <args> (client, phrase and args must be surrounded by []) (phrase arguments must be separated by a comma [,])");
		
		return Plugin_Handled;
	}
	
	any aArgs[32];
	
	BracketsPattern.GetSubString(0, strTarget, sizeof(strTarget), 0); TrimString(strTarget);
	BracketsPattern.GetSubString(0, strPhrase, sizeof(strPhrase), 1); TrimString(strPhrase);
	
	int iTarget = StringToInt(strTarget);
	
	if (iMatches == 3)
	{
		BracketsPattern.GetSubString(0, CmdBuffer, sizeof(CmdBuffer), 2);
		
		int iStrings = ExplodeString(CmdBuffer, ",", ExplodeBuffer, sizeof(ExplodeBuffer), sizeof(ExplodeBuffer[]));
		
		for (int iIndex = 0; iIndex < iStrings; iIndex++)
		{
			TrimString(ExplodeBuffer[iIndex]);
			
			if ((StringToIntEx(ExplodeBuffer[iIndex], aArgs[iIndex]) == strlen(ExplodeBuffer[iIndex])) ||
			    (StringToFloatEx(ExplodeBuffer[iIndex], aArgs[iIndex]) == strlen(ExplodeBuffer[iIndex])))
			{
				ExplodeBuffer[iIndex] = "\0";
			}
		}
	}
	
	if ((iTarget >= 1) && (iTarget <= MaxClients) && IsClientInGame(iTarget))
	{
		PrintPhrase(strPhrase, ExplodeBuffer, aArgs, false, iTarget);
	}
	
	return Plugin_Handled;
}

void PrintPhrase(const char[] strPhrase, const char strArgs[32][255], const any aArgs[32], bool bAll, int iClient = -1)
{
	// Pre-build arguments to avoid heap exhaustion from inline conversion
	any convertedArgs[29][256];
	
	for (int i = 0; i < 29; i++)
	{
		if (!strArgs[i][0])
		{
			// Numeric value
			convertedArgs[i][0] = aArgs[i];
		}
		else
		{
			// String value - copy character by character
			for (int j = 0; j < 255 && strArgs[i][j]; j++)
			{
				convertedArgs[i][j] = view_as<any>(strArgs[i][j]);
			}
		}
	}
	
	if (bAll)
	{
		CPrintToChatAll("%t", strPhrase, convertedArgs[0], convertedArgs[1], convertedArgs[2],
		                                 convertedArgs[3], convertedArgs[4], convertedArgs[5],
		                                 convertedArgs[6], convertedArgs[7], convertedArgs[8],
		                                 convertedArgs[9], convertedArgs[10], convertedArgs[11],
		                                 convertedArgs[12], convertedArgs[13], convertedArgs[14],
		                                 convertedArgs[15], convertedArgs[16], convertedArgs[17],
		                                 convertedArgs[18], convertedArgs[19], convertedArgs[20],
		                                 convertedArgs[21], convertedArgs[22], convertedArgs[23],
		                                 convertedArgs[24], convertedArgs[25], convertedArgs[26],
		                                 convertedArgs[27], convertedArgs[28]);
	}
	else
	{
		CPrintToChat(iClient, "%t", strPhrase, convertedArgs[0], convertedArgs[1], convertedArgs[2],
		                                       convertedArgs[3], convertedArgs[4], convertedArgs[5],
		                                       convertedArgs[6], convertedArgs[7], convertedArgs[8],
		                                       convertedArgs[9], convertedArgs[10], convertedArgs[11],
		                                       convertedArgs[12], convertedArgs[13], convertedArgs[14],
		                                       convertedArgs[15], convertedArgs[16], convertedArgs[17],
		                                       convertedArgs[18], convertedArgs[19], convertedArgs[20],
		                                       convertedArgs[21], convertedArgs[22], convertedArgs[23],
		                                       convertedArgs[24], convertedArgs[25], convertedArgs[26],
		                                       convertedArgs[27], convertedArgs[28]);
	}
}

