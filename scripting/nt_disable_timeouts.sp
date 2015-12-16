#pragma semicolon 1

#include <sourcemod>
#include "nt_ghostcap_natives" // need at least version 1.3.1, see url at variable g_ghostcapUrl below
#include <smlib>
#include <neotokyo>

#define PLUGIN_VERSION "0.1"

#define DEBUG 0
#define MAX_ROUNDS 99

new Handle:g_hDesiredScoreLimit;
new Handle:g_hNeoRestartThis;
new Handle:g_hNeoScoreLimit;
new Handle:g_hRoundEndTime;
new Handle:g_hRoundTime;
new Handle:g_hGhostcapVersion;
new Handle:g_hNextMap;
new Handle:g_hVoteMap_RoundsRemaining;

new g_roundNumber;
new g_ghostCapper;
new g_teamScore[4][MAX_ROUNDS]; // unassigned, spec, jinrai, nsf

new bool:playerSurvivedRound[MAXPLAYERS+1];

new Float:g_fRoundTime;

new String:g_tag[] = "[TIMEOUT]";
new String:g_ghostcapUrl[] = "https://github.com/softashell/nt-sourcemod-plugins/blob/master/nt_ghostcap.sp";

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
	
	// In case plugin gets loaded mid-game, try to guess current round.
	// Ties aren't considered, but we just want to know that game is already happening, as that affects the first Event_RoundStart call.
	g_roundNumber = GetTeamScore(TEAM_JINRAI) + GetTeamScore(TEAM_NSF);
}

public OnAllPluginsLoaded()
{
	g_hGhostcapVersion = FindConVar("sm_ntghostcapevent_version");
	if (g_hGhostcapVersion == null)
		SetFailState("This plugin requires Soft as HELL's Ghost cap plugin, version 1.3.1 or newer: %s", g_ghostcapUrl);
}

public OnConfigsExecuted()
{
	// Restore normal score limit so Sourcemod's voting will trigger normally
	SetConVarInt( g_hNeoScoreLimit, GetConVarInt(g_hDesiredScoreLimit) );
}

public OnMapEnd()
{
	g_roundNumber = 0;
}

public OnClientDisconnect(client)
{
	playerSurvivedRound[client] = false; // Snake? SNAAKE
}

public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	g_fRoundTime = GetGameTime();
	CreateTimer(1.0, Timer_CheckWinCondition);
	
	g_roundNumber++;
	
	g_teamScore[TEAM_JINRAI][g_roundNumber] = GetTeamScore(TEAM_JINRAI);
	g_teamScore[TEAM_NSF][g_roundNumber] = GetTeamScore(TEAM_NSF);
	
	// First round, we don't need to check for timeouts. Stop here.
	if (g_roundNumber == 1)
		return Plugin_Continue;
	
	g_ghostCapper = Ghostcap_CapInfo();
	
	if (g_ghostCapper == TEAM_JINRAI || g_ghostCapper == TEAM_NSF)
		return Plugin_Continue;
	
	new survivors[4]; // unassigned, spec, jinrai, nsf
	
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
	
	if (survivors[TEAM_JINRAI] > 0 && survivors[TEAM_NSF] > 0)
		CancelRound();
	
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
#if DEBUG
		PrintToChatAll("DED");
#endif	
	}
#if DEBUG
	else
	{
		PrintToChatAll("DED, but not in time");
	}
	
	PrintToServer("Death time: %f. round max length: %f.", deathTime, roundMaxLength);
#endif
}

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));
	playerSurvivedRound[client] = true;
}

void CancelRound()
{
	PrintToChatAll("%s Round timed out. No team point awarded.", g_tag);
	
	new lastRound = g_roundNumber - 1;
	
	SetTeamScore(TEAM_JINRAI, g_teamScore[TEAM_JINRAI][lastRound]);
	SetTeamScore(TEAM_NSF, g_teamScore[TEAM_NSF][lastRound]);
}

public Action:Timer_CheckWinCondition(Handle:timer)
{
	new scoreLimit = GetConVarInt(g_hDesiredScoreLimit);
	
	if (GetTeamScore(TEAM_JINRAI) >= scoreLimit)
	{
		PrintToChatAll( "%s Jinrai wins %i - %i", g_tag, g_teamScore[TEAM_JINRAI][g_roundNumber], g_teamScore[TEAM_NSF][g_roundNumber] );
		
		decl String:nextMap[128];
		GetConVarString( g_hNextMap, nextMap, sizeof(nextMap) );
		PrintToChatAll("Next level: %s", nextMap);
		
		CreateTimer( GetConVarFloat(g_hRoundEndTime), Timer_MapChange );
	}
	
	else if (GetTeamScore(TEAM_NSF) >= scoreLimit)
	{
		PrintToChatAll( "%s NSF wins %i - %i", g_tag, g_teamScore[TEAM_NSF][g_roundNumber], g_teamScore[TEAM_JINRAI][g_roundNumber] );
		
		decl String:nextMap[128];
		GetConVarString( g_hNextMap, nextMap, sizeof(nextMap) );
		PrintToChatAll("Next level: %s", nextMap);
		
		CreateTimer( GetConVarFloat(g_hRoundEndTime), Timer_MapChange );
	}
	
	// We've finished voting for nextmap. Now increase the native roundcount to max amount so it doesn't get in the way of our mapchange method.		
	if (
			(GetConVarInt(g_hDesiredScoreLimit) <= 2 && g_roundNumber > 1) ||
			
			(
				(
					GetTeamScore(TEAM_JINRAI) >= scoreLimit - GetConVarInt(g_hVoteMap_RoundsRemaining) ||
					GetTeamScore(TEAM_NSF) >= scoreLimit - GetConVarInt(g_hVoteMap_RoundsRemaining)
				)
				&&
				(
					GetConVarInt(g_hDesiredScoreLimit) > 2
				)
			)
		)
		{
			SetConVarInt(g_hNeoScoreLimit, 99);
		}
}

public Event_NeoRestartThis(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	new isRestarting = StringToInt(newVal);
	
	if (isRestarting)
		g_roundNumber = 0;
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