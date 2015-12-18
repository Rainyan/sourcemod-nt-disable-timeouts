#pragma semicolon 1

#include <sourcemod>
#include <smlib>
#include <neotokyo>

#define PLUGIN_VERSION "0.1.4.2"

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

new bool:playerSurvivedRound[MAXPLAYERS+1];

new Float:g_fRoundTime;

new String:g_tag[] = "[TIMEOUT]";

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
}

public OnAllPluginsLoaded()
{
	new Handle:g_hGhostcapVersion = FindConVar("sm_ntghostcapevent_version");
	new String:g_ghostcapUrl[] = "https://github.com/softashell/nt-sourcemod-plugins/blob/master/scripting/nt_ghostcap.sp";
	
	// Look for ghost cap plugin's version variable
	if (g_hGhostcapVersion == null)
		SetFailState("This plugin requires Soft as HELL's Ghost cap plugin: %s", g_ghostcapUrl);
	
	// Get the ghost cap plugin version
	decl String:ghostcapVersion[16];
	GetConVarString( g_hGhostcapVersion, ghostcapVersion, sizeof(ghostcapVersion) );
	CloseHandle(g_hGhostcapVersion);
	
	decl String:ghostcapVersion_Numeric[16];
	new stringpos;
	
	for (new i = 0; i < strlen(ghostcapVersion); i++)
	{
		if ( IsCharNumeric(ghostcapVersion[i]) )
			ghostcapVersion_Numeric[stringpos++] = ghostcapVersion[i];
	}
	ghostcapVersion_Numeric[stringpos] = 0; // string terminator
	
	if (
			(strlen(ghostcapVersion_Numeric) >= 3 && StringToInt(ghostcapVersion_Numeric) < 151)	|| // 3+ digit version numbers
			(strlen(ghostcapVersion_Numeric) == 2 && StringToInt(ghostcapVersion_Numeric) < 16)		|| // 2 digit version numbers
			(strlen(ghostcapVersion_Numeric) == 1 && StringToInt(ghostcapVersion_Numeric) < 2)		|| // 1 digit version numbers
			(strlen(ghostcapVersion_Numeric) < 1) // version string has no numbers, treat as error
		)
		{
			SetFailState("This plugin requires Soft as HELL's Ghost cap plugin to be running version 1.5.1 or higher: %s", g_ghostcapUrl);
		}
}

public OnConfigsExecuted()
{
	// Restore normal score limit so Sourcemod's voting will trigger normally
	SetConVarInt( g_hNeoScoreLimit, GetConVarInt(g_hDesiredScoreLimit) );
}

public OnMapStart()
{
	g_roundNumber = GetTeamScore(TEAM_JINRAI) + GetTeamScore(TEAM_NSF);
}

public OnClientDisconnect(client)
{
	playerSurvivedRound[client] = false; // Snake? SNAAKE
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
		
		if (!playerSurvivedRound[i])
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
			CancelRound(); // Cancel the team's round point gained
		}
	}
	
	return Plugin_Handled;
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new Float:roundMaxLength = GetConVarFloat(g_hRoundTime) * 60;
	new Float:deathTime = GetGameTime() - g_fRoundTime;
	
	if (deathTime < roundMaxLength)
	{
		new victim = GetClientOfUserId(GetEventInt(event, "userid"));
		playerSurvivedRound[victim] = false;
	}
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	
	if ( !Client_IsValid(client) || !IsClientInGame(client) )
		return Plugin_Handled;
	
	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
		return Plugin_Handled;
	
	// Round started already, client cannot spawn as a living player
	new Float:currentTime = GetGameTime();
	if (currentTime - g_fRoundTime > 15 + 1) // Freezetime is 15 secs, but the timer isn't 100% accurate. Added one second for safety.
		return Plugin_Handled;
	
	playerSurvivedRound[client] = true;
	
	return Plugin_Handled;
}

public Action:Timer_ResetGhostCapper(Handle:timer)
{
	g_ghostCappingTeam = TEAM_NONE; // Reset ghost cap var
}

void CancelRound()
{
	PrintToChatAll("%s Round timed out. No team point awarded.", g_tag);
	
	new lastRound = g_roundNumber - 1;
	
	if (lastRound < 1)
	{
		LogError("Tried to revert to team scores from round %i. Reverted to round 1 scores instead.", lastRound);
		lastRound = 1;
	}
	
	SetTeamScore(TEAM_JINRAI, g_teamScore[TEAM_JINRAI][lastRound]);
	SetTeamScore(TEAM_NSF, g_teamScore[TEAM_NSF][lastRound]);
}

public Action:Timer_CheckWinCondition(Handle:timer)
{	
	if ( GetTeamScore(TEAM_JINRAI) >= GetConVarInt(g_hDesiredScoreLimit) )
	{
		PrintToChatAll( "%s Jinrai wins %i - %i", g_tag, g_teamScore[TEAM_JINRAI][g_roundNumber], g_teamScore[TEAM_NSF][g_roundNumber] );
		
		decl String:nextMap[128];
		GetConVarString( g_hNextMap, nextMap, sizeof(nextMap) );
		PrintToChatAll("Next level: %s", nextMap);
		
		CreateTimer( GetConVarFloat(g_hRoundEndTime), Timer_MapChange );
	}
	
	else if ( GetTeamScore(TEAM_NSF) >= GetConVarInt(g_hDesiredScoreLimit) )
	{
		PrintToChatAll( "%s NSF wins %i - %i", g_tag, g_teamScore[TEAM_NSF][g_roundNumber], g_teamScore[TEAM_JINRAI][g_roundNumber] );
		
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