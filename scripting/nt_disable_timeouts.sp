#pragma semicolon 1

#include <sourcemod>
#include <smlib>
#include <neotokyo>

#define PLUGIN_VERSION "0.1.4.7"
#define DEBUG 1

#define MAX_ROUNDS 99

new Handle:g_hDesiredScoreLimit;
new Handle:g_hNeoRestartThis;
new Handle:g_hNeoScoreLimit;
new Handle:g_hRoundEndTime;
new Handle:g_hRoundTime;
new Handle:g_hNextMap;
new Handle:g_hVoteMap_RoundsRemaining;

new g_roundNumber;
new g_ghostCappingTeam;
new g_teamScore[4][MAX_ROUNDS]; // unassigned, spec, jinrai, nsf

new bool:g_playerSurvivedRound[MAXPLAYERS+1];

new Float:g_fRoundTime;

new String:g_tag[] = "[TIMEOUT]";

#if DEBUG
new String:g_path_logDebug[] = "logs/timeouts";
new String:g_teamName[][] = {
	"Unassigned",
	"Spectator",
	"Jinrai",
	"NSF"
};
#endif

public Plugin:myinfo = {
	name			= "NT Disable Timeouts",
	description	= "Disable timeout wins for NT",
	version		= PLUGIN_VERSION,
	author		= "Rain",
	url				= "https://github.com/Rainyan/sourcemod-nt-disable-timeouts"
};

public OnPluginStart()
{
	g_hRoundEndTime					= FindConVar("mp_chattime");
	g_hRoundTime						= FindConVar("neo_round_timelimit");
	g_hNeoScoreLimit					= FindConVar("neo_score_limit");
	g_hNeoRestartThis					= FindConVar("neo_restart_this");
	g_hNextMap							= FindConVar("sm_nextmap");
	g_hVoteMap_RoundsRemaining	= FindConVar("sm_mapvote_startround");
	
	g_hDesiredScoreLimit = CreateConVar("sm_timeouts_scorelimit", "7", "How many points should a team reach to win the map. You would normally use neo_score_limit for controlling this.", _, true, 1.0);
	
	HookEvent("game_round_start",	Event_RoundStart);
	HookEvent("player_death",			Event_PlayerDeath);
	HookEvent("player_spawn",			Event_PlayerSpawn);
	
	HookConVarChange(g_hNeoRestartThis, Event_NeoRestartThis);
	HookConVarChange(g_hDesiredScoreLimit, Event_DesiredScoreLimit);
	
	CreateConVar("sm_timeouts_version", PLUGIN_VERSION, "NT Disable Timeouts plugin version", FCVAR_PLUGIN|FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);
	
#if DEBUG
	PrepareDebugLogFolder();
#endif
}

public OnAllPluginsLoaded()
{
	CheckGhostcapPluginCompatibility();
}

public OnConfigsExecuted()
{
	// Restore normal score limit so Sourcemod's voting will trigger normally
	SetConVarInt( g_hNeoScoreLimit, GetConVarInt(g_hDesiredScoreLimit) );
}

public OnMapStart()
{
	g_roundNumber = 0;
}

public OnMapEnd()
{
	for (new i = 0; i <= MaxClients; i++)
	{
		g_playerSurvivedRound[i] = false;
	}
}

public OnGhostCapture(client)
{
	if ( !Client_IsValid(client) )
	{
		LogError("Returned invalid client %i", client);
		return;
	}
	
	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		LogError("Returned client %i does not belong to team Jinrai or NSF, returned team id %i", client, team);
		return;
	}
	
	g_ghostCappingTeam = team;
}

public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_fRoundTime = GetGameTime();
	CreateTimer(1.0, Timer_CheckWinCondition);
	CreateTimer(5.0, Timer_ResetGhostCapper);
	
	g_roundNumber++;
	
	g_teamScore[TEAM_JINRAI][g_roundNumber] = GetTeamScore(TEAM_JINRAI);
	g_teamScore[TEAM_NSF][g_roundNumber] = GetTeamScore(TEAM_NSF);
	
	// First round, we don't need to check for timeouts. Stop here.
	if (g_roundNumber == 1)
		return Plugin_Continue;
	
	// There was a ghost capture. Stop here.
	if (g_ghostCappingTeam == TEAM_JINRAI || g_ghostCappingTeam == TEAM_NSF)
		return Plugin_Continue;
	
	new survivors[4]; // unassigned, spec, jinrai, nsf
	
	// Check survivor count on both teams
	for (new i = 1; i <= MaxClients; i++)
	{
		if ( !Client_IsValid(i) )
			continue;
		
		if (!g_playerSurvivedRound[i])
			continue;
		
		new team = GetClientTeam(i);
		if (team != TEAM_JINRAI && team != TEAM_NSF)
			continue;
		
		survivors[team]++;
	}
	
	// Both teams had players remaining after the timeout
	if (survivors[TEAM_JINRAI] > 0 && survivors[TEAM_NSF] > 0)
	{
		// Teams didn't reach a traditional NT tie by numbers
		if (survivors[TEAM_JINRAI] != survivors[TEAM_NSF])
		{
#if DEBUG
				decl String:timeoutTitle[128];
				FormatTime(timeoutTitle, sizeof(timeoutTitle), NULL_STRING);
				StrCat(timeoutTitle, sizeof(timeoutTitle), " - Timeout triggered.");
				LogDebug(timeoutTitle);
				
				decl String:scoreInfo[25];
				Format( scoreInfo, sizeof(scoreInfo), "Jinrai %i -- NFS %i", GetTeamScore(TEAM_JINRAI), GetTeamScore(TEAM_NSF) );
				LogDebug(scoreInfo);
				
				for (new i = 1; i <= MaxClients; i++)
				{
					decl String:clientName[MAX_NAME_LENGTH] = "<invalid client>";
					if ( Client_IsValid(i) && IsClientInGame(i) )
					{
						if ( IsFakeClient(i) )
							strcopy(clientName, sizeof(clientName), "<bot client>");
						else
							GetClientName( i, clientName, sizeof(clientName) );
					}
					
					LogDebug("Client %i (%s) - Survived = %b - Name: %s", i, g_teamName[GetClientTeam(i)], g_playerSurvivedRound[i], clientName);
				}
				
				LogDebug("");
#endif
			CancelRound(); // Cancel the team's round point gained
		}
	}
	
	ResetLivingState();
	
	return Plugin_Handled;
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new Float:roundMaxLength = GetConVarFloat(g_hRoundTime) * 60;
	new Float:deathTime = GetGameTime() - g_fRoundTime;
	
	if (deathTime < roundMaxLength)
	{
		new victim = GetClientOfUserId(GetEventInt(event, "userid"));
		g_playerSurvivedRound[victim] = false;
	}
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if ( DidPlayerReallySpawn(client) )
		g_playerSurvivedRound[client] = true;
}

bool DidPlayerReallySpawn(client)
{
	if ( !Client_IsValid(client) || !IsClientInGame(client) )
		return false;
	
	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
		return false;
	
	new Float:currentTime = GetGameTime();
	if (currentTime - g_fRoundTime > 30 + 1) // Spawn event triggered after round spawning is finished. Player cannot have spawned.
	{
		PrintToServer("Spawn time > 30+1. currentTime = %f. currentTime-roundTime = %f", currentTime, currentTime - g_fRoundTime);
		return false;
	}
	
	return true;
}

public Action:Timer_ResetGhostCapper(Handle:timer)
{
	g_ghostCappingTeam = TEAM_NONE; // Reset ghost cap var
}

void CancelRound()
{
	PrintToChatAll("%s Round timed out. No team point awarded.", g_tag);
	g_roundNumber--;
	
	if (g_roundNumber < 0)
	{
		LogError("Tried to revert to team scores from round %i. Reverted to 0th (first) round scores instead.", g_roundNumber);
		g_roundNumber = 0;
	}
	
	SetTeamScore(TEAM_JINRAI, g_teamScore[TEAM_JINRAI][g_roundNumber]);
	SetTeamScore(TEAM_NSF, g_teamScore[TEAM_NSF][g_roundNumber]);
}

public Action:Timer_CheckWinCondition(Handle:timer)
{	
	if ( GetTeamScore(TEAM_JINRAI) >= GetConVarInt(g_hDesiredScoreLimit) )
	{
		PrintToChatAll( "[SM] Jinrai wins %i - %i", g_teamScore[TEAM_JINRAI][g_roundNumber], g_teamScore[TEAM_NSF][g_roundNumber] );
		
		decl String:nextMap[128];
		GetConVarString( g_hNextMap, nextMap, sizeof(nextMap) );
		PrintToChatAll("Next level: %s", nextMap);
		
		CreateTimer( GetConVarFloat(g_hRoundEndTime), Timer_MapChange );
	}
	
	else if ( GetTeamScore(TEAM_NSF) >= GetConVarInt(g_hDesiredScoreLimit) )
	{
		PrintToChatAll( "[SM] NSF wins %i - %i", g_teamScore[TEAM_NSF][g_roundNumber], g_teamScore[TEAM_JINRAI][g_roundNumber] );
		
		decl String:nextMap[128];
		GetConVarString( g_hNextMap, nextMap, sizeof(nextMap) );
		PrintToChatAll("Next level: %s", nextMap);
		
		CreateTimer( GetConVarFloat(g_hRoundEndTime), Timer_MapChange );
	}
	
	if (GetConVarInt(g_hNeoScoreLimit) == MAX_ROUNDS)
		return Plugin_Handled;
	
	// We've finished voting for nextmap. Now increase the native roundcount to max amount so it doesn't get in the way of our mapchange method.
	if (
			(GetConVarInt(g_hDesiredScoreLimit) <= 2 && g_roundNumber > 1) ||
			
			(
				(
					GetTeamScore(TEAM_JINRAI) >= GetConVarInt(g_hDesiredScoreLimit) - GetConVarInt(g_hVoteMap_RoundsRemaining) ||
					GetTeamScore(TEAM_NSF) >= GetConVarInt(g_hDesiredScoreLimit) - GetConVarInt(g_hVoteMap_RoundsRemaining)
				)
				&&
				(
					GetConVarInt(g_hDesiredScoreLimit) > 2
				)
			)
		)
		{
			SetConVarInt(g_hNeoScoreLimit, MAX_ROUNDS);
		}
	
	return Plugin_Handled;
}

public Event_NeoRestartThis(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	new isRestarting = StringToInt(newVal);
	
	if (isRestarting)
	{
		g_ghostCappingTeam = TEAM_NONE;
		g_roundNumber = 0;
	}
}

public Event_DesiredScoreLimit(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	new newScoreLimit = StringToInt(newVal);
	
	new jinraiScore = GetTeamScore(TEAM_JINRAI);
	new nsfScore = GetTeamScore(TEAM_NSF);
	
	// Only update neo_score_limit to reflect sm_timeouts_scorelimit if we haven't triggered mapvote yet
	if ( jinraiScore <= newScoreLimit - GetConVarInt(g_hVoteMap_RoundsRemaining) &&
		nsfScore  <= newScoreLimit - GetConVarInt(g_hVoteMap_RoundsRemaining) )
		{
			SetConVarInt(g_hNeoScoreLimit, newScoreLimit);
		}
}

public Action:Timer_MapChange(Handle:timer)
{
	decl String:nextMap[128];
	GetConVarString( g_hNextMap, nextMap, sizeof(nextMap) );
	
	if (!IsMapValid(nextMap))
	{
		// For whatever reason we ended up with invalid nextmap.
		// Log error and use nt_dawn_ctg as fallback level.
		LogError("Attempted to load invalid map %s", nextMap);
		strcopy(nextMap, sizeof(nextMap), "nt_dawn_ctg");
	}
	
	ServerCommand("changelevel %s", nextMap);
}

void CheckGhostcapPluginCompatibility()
{
	new Handle:hGhostcapVersion = FindConVar("sm_ntghostcap_version");
	
	// Look for ghost cap plugin's version variable
	if (hGhostcapVersion == null)
	{
		new String:ghostcapUrl[] = "https://github.com/softashell/nt-sourcemod-plugins";
		SetFailState("This plugin requires Soft as HELL's Ghost cap plugin version 1.5.4 or newer: %s", ghostcapUrl);
	}
	
	CloseHandle(hGhostcapVersion);
}

#if DEBUG
void PrepareDebugLogFolder()
{
	decl String:path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), g_path_logDebug);
	if ( !DirExists(path) )
		CreateDirectory(path, 509);
}

void LogDebug(const String:message[], any ...)
{
	decl String:path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), g_path_logDebug);
	StrCat(path, sizeof(path), "/timeouts_debug.log");
	
	// Format according to SM format rules
	decl String:formatMsg[512];
	VFormat(formatMsg, sizeof(formatMsg), message, 2);
	
	new Handle:file = OpenFile(path, "a"); // fopen
	WriteFileLine(file, formatMsg);
	CloseHandle(file);
}
#endif

void ResetLivingState()
{
	for (new i = 1; i <= MaxClients; i++)
	{
		g_playerSurvivedRound[i] = false;
	}
}