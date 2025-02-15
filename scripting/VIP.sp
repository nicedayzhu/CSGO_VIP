#include <sourcemod>
#include <regex>
#include <VIP>

#define PLUGIN_AUTHOR "NoyB"
#define PLUGIN_VERSION "1.0"

#define DAY_TO_SECONDS 86400
#define MONTH_TO_DAY 30

enum struct Player
{
	char auth[32];
	char name[MAX_NAME_LENGTH];
	
	int expiration;
	
	void reset()
	{
		this.auth[0] = 0;
		this.name[0] = 0;
		
		this.expiration = 0;
	}
	
	bool isVip()
	{
		return this.expiration - GetTime() > 0;
	}
}

Player g_aPlayers[MAXPLAYERS + 1];

GlobalForward g_fwdVipGiven = null;
GlobalForward g_fwdVipLoaded = null;

Database g_dbDatabase = null;

bool g_bLate = false;
bool g_bWriting[MAXPLAYERS + 1] =  { false };

int g_iRounds = 0;
int g_iTarget[MAXPLAYERS + 1] =  { -1 };
int g_iDuration[MAXPLAYERS + 1] =  { 0 };

public Plugin myinfo = 
{
	name = "[CS:GO] VIP System", 
	author = PLUGIN_AUTHOR, 
	description = "", 
	version = PLUGIN_VERSION, 
	url = "https://steamcommunity.com/id/s4muray"
};

public void OnPluginStart()
{
	LoadTranslations("csgo-vip.phrases");
	SQL_MakeConnection();
	
	HookEvent("round_start", Event_RoundStart);
	
	RegAdminCmd("sm_vip", Command_VIP, ADMFLAG_ROOT, "VIP Management");
	RegAdminCmd("sm_addvip", Command_AddVIP, ADMFLAG_ROOT, "This command is used to add a vip using steamid")
	
	if (g_bLate)
		for (int i = 1; i <= MaxClients; i++)if (IsClientInGame(i))OnClientPostAdminCheck(i);
}

/* Natives */

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	g_bLate = late;
	
	CreateNative("VIP_IsPlayerVIP", Native_IsPlayerVIP);
	
	g_fwdVipLoaded = new GlobalForward("VIP_OnPlayerLoaded", ET_Event, Param_Cell);
	g_fwdVipGiven = new GlobalForward("VIP_OnPlayerGiven", ET_Event, Param_Cell, Param_Cell);
	
	RegPluginLibrary("[CS:GO] VIP System");
	return APLRes_Success;
}

public int Native_IsPlayerVIP(Handle plugin, int numParams)
{
	int iClient = GetNativeCell(1);
	if (iClient < 1 || iClient > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index (%d)", iClient);
	}
	if (!IsClientConnected(iClient))
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Client %d is not connected", iClient);
	}
	
	return g_aPlayers[iClient].isVip();
}

/* */

/* Events */

public void OnMapStart()
{
	g_iRounds = 0;
}

public void OnClientPostAdminCheck(int client)
{
	g_aPlayers[client].reset();
	if (!GetClientAuthId(client, AuthId_Steam2, g_aPlayers[client].auth, sizeof(g_aPlayers[].auth)))
	{
		KickClient(client, "Verification problem, please reconnect");
		return;
	}
	
	GetClientName(client, g_aPlayers[client].name, sizeof(g_aPlayers[].name));
	strcopy(g_aPlayers[client].name, sizeof(g_aPlayers[].name), SQL_SecureString(g_aPlayers[client].name));
	
	SQL_LoadUser(client);
}

public Action Event_RoundStart(Event event, char[] name, bool dontBroadcast)
{
	g_iRounds++;
}

/* */

/* Commands */

public Action Command_VIP(int client, int args)
{
	if (!client)
	{
		PrintToServer("This command is for in-game only.");
		return Plugin_Handled;
	}
	
	Menus_ShowMain(client);
	return Plugin_Handled;
}

public Action Command_AddVIP(int client, int args)
{
	if (!client)
	{
		PrintToServer("This command is for in-game only.");
		return Plugin_Handled;
	}
	
	PrintToChat(client, "args = %d", args);
	if (args != 3)
	{
		ReplyToCommand(client, "%s Usage: sm_addvip \"<SteamID>\" <days> \"<name>\"", PREFIX);
		return Plugin_Handled;
	}
	
	char szArg[32], szArg2[10], szArg3[32];
	GetCmdArg(1, szArg, sizeof(szArg));
	GetCmdArg(2, szArg2, sizeof(szArg2));
	GetCmdArg(3, szArg3, sizeof(szArg3));
	
	// Regex rSteam = new Regex("/^STEAM_[0-5]:[0-1]:\\d{8}$/");
	Regex rSteam = new Regex("^STEAM_[0-1]:[0-1]:\\d{8}$");
	
	if (rSteam.Match(szArg) != 1)
	{
		delete rSteam;
		
		ReplyToCommand(client, "%s Invalid steamid entered, please try again.", PREFIX);
		return Plugin_Handled;
	}
	
	delete rSteam;
	int iDuration = StringToInt(szArg2);
	if (iDuration < 0)
	{
		ReplyToCommand(client, "%s Invalid amount of days entered, please try again.", PREFIX);
		return Plugin_Handled;
	}
	
	SQL_AddOfflineVIP(szArg, iDuration, szArg3);
	ShowActivity2(client, PREFIX_ACTIVITY, "Gave a vip to \x02\"%s\" \x02\"%s\" \x01for \x04%s \x01days.", szArg, szArg3, addCommas(iDuration));
	
	return Plugin_Handled;
}

/* */

/* Menus */

void Menus_ShowMain(int client)
{
	char buffer[60];
	Menu menu = new Menu(Handler_MainMenu);
	menu.SetTitle("%s %T\n ", PREFIX_MENU, "VIP Management", client); //translations use client LANG, https://wiki.alliedmods.net/Translations_(SourceMod_Scripting)

	Format(buffer, sizeof(buffer), "%T", "add", client);
	menu.AddItem("add", buffer);
	Format(buffer, sizeof(buffer), "%T", "manage", client);
	menu.AddItem("manage", buffer);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_MainMenu(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Select)
	{
		char szInfo[32];
		menu.GetItem(itemNum, szInfo, sizeof(szInfo));
		
		if (!strcmp(szInfo, "add"))
		{
			Menus_SelectPlayer(client);
		} else if (!strcmp(szInfo, "manage")) {
			g_dbDatabase.Query(SQL_ManageVips, "SELECT * FROM `vips`", GetClientSerial(client));
		}
	}
}

void Menus_SelectPlayer(int client)
{
	Menu menu = new Menu(Handler_PlayerSelection);
	menu.SetTitle("%s Select a Player:\n ", PREFIX_MENU);
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !g_aPlayers[i].isVip())
		{
			char szIndex[10], szName[MAX_NAME_LENGTH];
			IntToString(i, szIndex, sizeof(szIndex));
			GetClientName(i, szName, sizeof(szName));
			
			menu.AddItem(szIndex, szName);
		}
	}
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_PlayerSelection(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Cancel && itemNum == MenuCancel_ExitBack)
	{
		Menus_ShowMain(client);
	} else if (action == MenuAction_Select) {
		char szInfo[10];
		menu.GetItem(itemNum, szInfo, sizeof(szInfo));
		
		int iTarget = StringToInt(szInfo);
		if (!IsClientInGame(iTarget))
		{
			PrintToChat(client, "%s Target not available anymore.", PREFIX);
			return;
		}
		
		g_iTarget[client] = iTarget;
		Menus_ShowPlayer(client);
	}
}

void Menus_ShowPlayer(int client)
{
	Menu menu = new Menu(Handler_PlayerManagement);
	menu.SetTitle("%s Adding a VIP:\n ", PREFIX_MENU);
	
	char szBuffer[MAX_NAME_LENGTH * 2];
	GetClientName(g_iTarget[client], szBuffer, sizeof(szBuffer));
	
	Format(szBuffer, sizeof(szBuffer), "Target: %s", szBuffer);
	menu.AddItem("target", szBuffer);
	
	Format(szBuffer, sizeof(szBuffer), "Choose Duration");
	menu.AddItem("duration", szBuffer);
	menu.AddItem("add", "Add VIP");
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Handler_PlayerManagement(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Cancel && itemNum == MenuCancel_ExitBack)
	{
		Menus_SelectPlayer(client);
	} else if (action == MenuAction_Select) {
		char szInfo[32];
		menu.GetItem(itemNum, szInfo, sizeof(szInfo));
		
		if (!strcmp(szInfo, "target"))
		{
			Menus_SelectPlayer(client);
		} else if (!strcmp(szInfo, "duration")) {
			g_bWriting[client] = true;
			Menus_ShowDuration(client);
			// PrintToChat(client, "%s Write the amount of days you want or \x02-1 \x01to abort.", PREFIX);
		} else if (!strcmp(szInfo, "add")) {
			if (!IsClientInGame(g_iTarget[client]))
			{
				PrintToChat(client, "%s Target is not available anymore.", PREFIX);
				Menus_SelectPlayer(client);
				return;
			}
			
			if (g_iDuration[client] <= 0)
			{
				PrintToChat(client, "%s Invalid time entered, please try again.", PREFIX);
				Menus_ShowPlayer(client);
				return;
			}
			
			if (g_aPlayers[g_iTarget[client]].isVip())
			{
				PrintToChat(client, "%s Target is already a VIP.", PREFIX);
				Menus_SelectPlayer(client);
				return;
			}
			
			Call_StartForward(g_fwdVipGiven);
			Call_PushCell(g_iTarget[client]);
			Call_PushCell(g_iDuration[client]);
			Call_Finish();
			
			SQL_AddVIP(client);
			OnClientPostAdminCheck(g_iTarget[client]);
			
			ShowActivity2(client, PREFIX_ACTIVITY, "Gave a vip to \x02%N \x01for \x04%s \x01days.", g_iTarget[client], addCommas(g_iDuration[client]));
			
			g_iTarget[client] = -1;
			g_iDuration[client] = 0;
		}
	}
}

void Menus_ShowDuration(int client)
{
	Menu menu = new Menu(Handler_DurationManagement);
	menu.SetTitle("%s Choose a Duration:\n ", PREFIX_MENU);
	
	menu.AddItem("testVip", "1 day test");
	menu.AddItem("1", "1 Month");
	menu.AddItem("2", "2 Month");
	
	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

int g_iTestVipDuration = 1; //1 day vip test
public int Handler_DurationManagement(Handle menu, MenuAction action, int client, int item) {
	char cValue[32];
	GetMenuItem(menu, item, cValue, sizeof(cValue));
	if (action == MenuAction_Select) {
		if (StrEqual(cValue, "testVip")) {
			g_iDuration[client] = g_iTestVipDuration;
			// PrintToConsole(client, "1 day test vip");
			Menus_ShowPlayer(client);
		} else {
			g_iDuration[client] = StringToInt(cValue) * MONTH_TO_DAY;
			// PrintToConsole(client, "%d month vip", g_iDuration[client]);
			Menus_ShowPlayer(client);
		}
	}
}
public int Handler_ManageVIPs(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Cancel && itemNum == MenuCancel_ExitBack)
	{
		Menus_ShowMain(client);
	} else if (action == MenuAction_Select) {
		char szAuth[32];
		menu.GetItem(itemNum, szAuth, sizeof(szAuth));
		
		char szQuery[512];
		FormatEx(szQuery, sizeof(szQuery), "SELECT * FROM `vips` WHERE `auth` = '%s'", szAuth);
		g_dbDatabase.Query(SQL_FetchVIP, szQuery, GetClientSerial(client));
	}
}

public int Handler_ManageVIP(Menu menu, MenuAction action, int client, int itemNum)
{
	if (action == MenuAction_Cancel && itemNum == MenuCancel_ExitBack)
	{
		g_dbDatabase.Query(SQL_ManageVips, "SELECT * FROM `vips`", GetClientSerial(client));
	} else if (action == MenuAction_Select) {
		char szAuth[32];
		menu.GetItem(itemNum, szAuth, sizeof(szAuth));
		SQL_RemoveVIP(szAuth);
	}
}

/* */

/* Functions */

int getOnlineUsers()
{
	int iCount = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i))
			iCount++;
	}
	
	return iCount;
}

char addCommas(int value, const char[] seperator = ",")
{
	char buffer[MAX_NAME_LENGTH];
	buffer[0] = '\0';
	int divisor = 1000;
	
	while (value >= 1000 || value <= -1000)
	{
		int offcut = value % divisor;
		value = RoundToFloor(float(value) / float(divisor));
		Format(buffer, MAX_NAME_LENGTH, "%c%03.d%s", seperator, offcut, buffer);
	}
	
	Format(buffer, MAX_NAME_LENGTH, "%d%s", value, buffer);
	return buffer;
}

/* */

/* Database */

void SQL_MakeConnection()
{
	if (g_dbDatabase != null)
		delete g_dbDatabase;
	
	char szError[512];
	g_dbDatabase = SQL_Connect(DATABASE_ENTRY, true, szError, sizeof(szError));
	if (g_dbDatabase == null)
		SetFailState("Cannot connect to datbase error: %s", szError);
	
	g_dbDatabase.Query(SQL_CheckForErrors, "CREATE TABLE IF NOT EXISTS `vips` (`auth` VARCHAR(32) NOT NULL, `name` VARCHAR(64) NOT NULL, `expiration` INT(10) NOT NULL, UNIQUE(`auth`))");
}

void SQL_LoadUser(int client)
{
	char szQuery[512];
	FormatEx(szQuery, sizeof(szQuery), "SELECT `expiration` FROM `vips` WHERE `auth` = '%s'", g_aPlayers[client].auth);
	g_dbDatabase.Query(SQL_LoadUser_CB, szQuery, GetClientSerial(client));
}

public void SQL_LoadUser_CB(Database db, DBResultSet results, const char[] error, any data)
{
	if (!StrEqual(error, ""))
	{
		LogError("Database error, %s", error);
		return;
	}
	
	int iClient = GetClientFromSerial(data);
	if (results.FetchRow())
	{
		int iExpiration = results.FetchInt(0);
		if (iExpiration - GetTime() > 0)
		{
			g_aPlayers[iClient].expiration = iExpiration;
			
			Call_StartForward(g_fwdVipLoaded);
			Call_PushCell(iClient);
			Call_Finish();
		} else if (GetMaxHumanPlayers() < getOnlineUsers() && g_iRounds > 1) {
			KickClient(iClient, "Server is full")
		}
	}
}

void SQL_AddVIP(int client)
{
	int iTarget = g_iTarget[client];
	int iExpiration = GetTime() + (g_iDuration[client] * DAY_TO_SECONDS);
	
	char szQuery[512];
	FormatEx(szQuery, sizeof(szQuery), "INSERT INTO `vips` (`auth`, `name`, `expiration`) VALUES ('%s', '%s', %d)", g_aPlayers[iTarget].auth, g_aPlayers[iTarget].name, iExpiration);
	g_dbDatabase.Query(SQL_CheckForErrors, szQuery);
}

void SQL_AddOfflineVIP(char[] auth, int duration, char[] name)
{
	int iExpiration = GetTime() + (duration * DAY_TO_SECONDS);
	
	char szQuery[512];
	FormatEx(szQuery, sizeof(szQuery), "INSERT INTO `vips` (`auth`, `name`, `expiration`) VALUES ('%s', '%s', %d) ON DUPLICATE KEY UPDATE `expiration` = %d", auth, name, iExpiration, iExpiration);
	g_dbDatabase.Query(SQL_CheckForErrors, szQuery);
}

void SQL_RemoveVIP(char[] auth)
{
	char szQuery[512];
	FormatEx(szQuery, sizeof(szQuery), "DELETE FROM `vips` WHERE `auth` = '%s'", auth);
	g_dbDatabase.Query(SQL_CheckForErrors, szQuery);
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !strcmp(g_aPlayers[i].auth, auth))
		{
			g_aPlayers[i].expiration = 0;
			break;
		}
	}
}

public void SQL_ManageVips(Database db, DBResultSet results, const char[] error, any data)
{
	if (!StrEqual(error, ""))
	{
		LogError("Database error, %s", error);
		return;
	}
	
	int iClient = GetClientFromSerial(data);
	
	Menu menu = new Menu(Handler_ManageVIPs);
	menu.SetTitle("%s Manage VIPs - Select a Player:\n ", PREFIX_MENU);
	
	int iCount = 0;
	while (results.FetchRow())
	{
		iCount++;
		
		char szAuth[32], szName[MAX_NAME_LENGTH];
		results.FetchString(0, szAuth, sizeof(szAuth));
		results.FetchString(1, szName, sizeof(szName));
		
		menu.AddItem(szAuth, szName);
	}
	
	if (!iCount)
		menu.AddItem("", "No vip players were found in the database.", ITEMDRAW_DISABLED);
	
	menu.ExitBackButton = true;
	menu.Display(iClient, MENU_TIME_FOREVER);
}

public void SQL_FetchVIP(Database db, DBResultSet results, const char[] error, any data)
{
	if (!StrEqual(error, ""))
	{
		LogError("Database error, %s", error);
		return;
	}
	
	int iClient = GetClientFromSerial(data);
	
	if (results.FetchRow())
	{
		char szAuth[32], szName[MAX_NAME_LENGTH];
		results.FetchString(0, szAuth, sizeof(szAuth));
		results.FetchString(1, szName, sizeof(szName));
		
		int iExpiration = results.FetchInt(2);
		char szTime[64];
		FormatTime(szTime, sizeof(szTime), "%d/%m/%Y %R", iExpiration);
		
		Menu menu = new Menu(Handler_ManageVIP);
		menu.SetTitle("%s Manage VIP - Viewing \"%s\"\nExpire Date: %s\n ", PREFIX_MENU, szName, szTime);
		menu.AddItem(szAuth, "Remove VIP");
		menu.ExitBackButton = true;
		menu.Display(iClient, MENU_TIME_FOREVER);
	}
}

char SQL_SecureString(char[] string)
{
	char szEscaped[256];
	g_dbDatabase.Escape(string, szEscaped, sizeof(szEscaped));
	return szEscaped;
}

public void SQL_CheckForErrors(Database db, DBResultSet results, const char[] error, any data)
{
	if (!StrEqual(error, ""))
	{
		LogError("Database error, %s", error);
		return;
	}
}

/* */
