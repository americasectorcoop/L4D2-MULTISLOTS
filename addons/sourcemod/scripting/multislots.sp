#pragma semicolon 1
#include <sourcemod>
#include <sdktools>

#if SOURCEMOD_V_MINOR < 7
 #error Old version sourcemod!
#endif
#pragma newdecls required

#define PLUGIN_VERSION            "3.0"
#define CVAR_FLAGS                FCVAR_NOTIFY
#define DELAY_KICK_FAKECLIENT 		0.1
#define DELAY_KICK_NONEEDBOT      0.5
#define TEAM_SPECTATORS           1
#define TEAM_SURVIVORS            2
#define TEAM_INFECTED             3
#define DAMAGE_EVENTS_ONLY        1
#define	DAMAGE_YES                2

ConVar hMaxSurvivors;
Handle timer_SpecCheck = null;
ConVar hKickIdlers;
bool gbVehicleLeaving;
bool gbPlayedAsSurvivorBefore[MAXPLAYERS+1];
bool gbFirstItemPickedUp;
bool gbPlayerPickedUpFirstItem[MAXPLAYERS+1];
int giIdleTicks[MAXPLAYERS+1];

Handle hRoundRespawn = null;
GameData gGameConf = null;

//************************************************//
//********     ANTI RECONNECT PART    ************//
//************************************************//
bool Played[MAXPLAYERS + 1];
Handle Join_Timer[MAXPLAYERS+1];

KeyValues g_kvDB = null;

//CVars' handles
ConVar cvar_no_bots_survivors = null;
ConVar cvar_ar_time = null;
ConVar cvar_ar_admin_immunity = null;
ConVar cvar_ar_disconnect_by_user_only = null;
ConVar cvar_lan = null;

//Cvars' varibles
bool isLAN = false;
int ar_time = 300;
int ar_disconnect_by_user_only = true;
int ar_admin_immunity = false;

//************************************************//

bool g_iMapFix = false;
bool IsTimeTeleport;
bool isBotsOn;
bool isBotsOff = false;  // bots included
bool g_bBlockJoinCommand;
int Attempt[MAXPLAYERS + 1];

float g_Vpos[3];

public Plugin myinfo = {
  name          = "L4D2 MultiSlots for coop",
  author        = "SwiftReal, MI 5",
  description   = "Allows additional survivor players in coop and survival",
  version       = PLUGIN_VERSION,
  url           = "N/A"
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
  // This plugin will only work on L4D 1/2
  char GameName[64];
  GetGameFolderName(GameName, sizeof(GameName));
  if (StrContains(GameName, "left4dead", false) == -1)
    return APLRes_Failure;

  return APLRes_Success;
}

public void OnPluginStart()
{
  LoadTranslations("l4dmultislots.phrases");

  // Anti reconnect part
  g_kvDB = new KeyValues("antireconnect_multislot");

  cvar_ar_time = CreateConVar("l4d_multislots_anti_reconnect_time", "300", "Time in seconds players must to wait before connect to the server again after disconnecting, 0 = disabled", 0, true, 0.0);
  cvar_ar_disconnect_by_user_only = CreateConVar("l4d_multislots_anti_reconnect_disconnect_by_user_only", "1", "\n0 = always block players from reconnecting\n1 = block player from reconnecting only if a client \"disconnected by user\"", 0, true, 0.0, true, 1.0);
  cvar_ar_admin_immunity = CreateConVar("l4d_multislots_anti_reconnect_admin_immunity", "1", "0 = disabled, 1 = protect admins from Anti-Reconnect functionality", 0, true, 0.0, true, 1.0);
  cvar_lan = FindConVar("sv_lan");

  cvar_ar_time.AddChangeHook(OnCVarChange);
  cvar_ar_disconnect_by_user_only.AddChangeHook(OnCVarChange);
  cvar_ar_admin_immunity.AddChangeHook(OnCVarChange);
  cvar_lan.AddChangeHook(OnCVarChange);

  HookEvent("player_disconnect", Event_PlayerDisconnect, EventHookMode_Post);
  HookEvent("round_start", Event_RoundStart);

  HookEvent("map_transition", Event_MapTransition, EventHookMode_Post);

  // Create plugin version cvar and set it
  CreateConVar("l4d_multislots_version", PLUGIN_VERSION, "L4D2 MultiSlots version", CVAR_FLAGS|FCVAR_SPONLY|FCVAR_REPLICATED);
  FindConVar("l4d_multislots_version").SetString(PLUGIN_VERSION);

  // Register commands
  RegAdminCmd("sm_addbot", AddBot, ADMFLAG_GENERIC, "Attempt to add and teleport a survivor bot");
  RegAdminCmd("sm_spec", Spec, ADMFLAG_ROOT, "");
  RegAdminCmd("sm_surv", Surv, ADMFLAG_ROOT, "");
  RegAdminCmd("sm_tweak", Tweak, ADMFLAG_ROOT, "Tweak some settings");
  RegAdminCmd("sm_coordinates", Coord, ADMFLAG_ROOT, "Find out the coordinates of the place for teleport");
  RegConsoleCmd("sm_join", JoinTeam, "Attempt to join Survivors");

  // Register cvars
  hMaxSurvivors	= CreateConVar("l4d_multislots_max_survivors", "25", "How many survivors allowed?", CVAR_FLAGS, true, 4.0, true, 32.0);
  hKickIdlers 	= CreateConVar("l4d_multislots_kickafk", "0", "Kick idle players? (0 = no  1 = player 5 min, admins kickimmune  2 = player 5 min, admins 10 min)", CVAR_FLAGS, true, 0.0, true, 2.0);

  // Hook events
  HookEvent("item_pickup", evtRoundStartAndItemPickup);
  HookEvent("player_left_start_area", evtPlayerLeftStart);
  HookEvent("survivor_rescued", evtSurvivorRescued);
  HookEvent("finale_vehicle_leaving", evtFinaleVehicleLeaving);
  HookEvent("mission_lost", evtMissionLost);
  HookEvent("player_activate", evtPlayerActivate, EventHookMode_Post);
  HookEvent("bot_player_replace", evtPlayerReplacedBot);
  HookEvent("player_bot_replace", evtBotReplacedPlayer);
  HookEvent("player_team", evtPlayerTeam);

  AddCommandListener(Client_JoinTeam, "jointeam");

  gGameConf = new GameData("l4d2multislots");
  if (gGameConf != null)
  {
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(gGameConf, SDKConf_Signature, "RoundRespawn");
    hRoundRespawn = EndPrepSDKCall();
    if (hRoundRespawn == null)
    {
      SetFailState("L4D_SM_Respawn: RoundRespawn Signature broken");
    }
    }
  else
  {
    SetFailState("could not find gamedata file at addons/sourcemod/gamedata/l4d2multislots.txt , you FAILED AT INSTALLING");
  }

  cvar_no_bots_survivors = FindConVar("director_no_survivor_bots");
}

public void OnMapStart()
{
  char sMap[64];
  GetCurrentMap(sMap, sizeof(sMap));

  g_iMapFix = false;

  if (strcmp(sMap, "c6m2_bedlam") == 0) g_iMapFix = true;
  else g_iMapFix = false;

  gbFirstItemPickedUp = false;
  isBotsOn = false;
  g_bBlockJoinCommand = false;

  // Anti reconnect part
  delete g_kvDB;
  g_kvDB = new KeyValues("antireconnect_multislot");
}

public bool OnClientConnect(int client, char[] rejectmsg, int maxlen)
{
  if (client)
  {
    gbPlayedAsSurvivorBefore[client] = false;
    gbPlayerPickedUpFirstItem[client] = false;
    giIdleTicks[client] = 0;
  }
  return true;
}

public void OnClientDisconnect(int client)
{
  gbPlayedAsSurvivorBefore[client] = false;
  gbPlayerPickedUpFirstItem[client] = false;

  if (Join_Timer[client] != null)
  {
    KillTimer(Join_Timer[client]);
    Join_Timer[client] = null;
  }
}

public void OnMapEnd()
{
  StopTimers();
  gbVehicleLeaving = false;
  gbFirstItemPickedUp = false;
}

////////////////////////////////////
// Callbacks
////////////////////////////////////
public Action AddBot(int client, int args)
{
  if (SpawnFakeClientAndTeleport())
    PrintToChatAll("Survivor bot spawned and teleported.");

  return Plugin_Handled;
}

public Action Spec(int client, int args)
{
  if (client)
    ChangeClientTeam(client, TEAM_SPECTATORS);

  return Plugin_Handled;
}

public Action Surv(int client, int args)
{
  if (client)
    ChangeClientTeam(client, TEAM_SURVIVORS);

  return Plugin_Handled;
}

//************************************************//
//********     ANTI RECONNECT PART    ************//
//************************************************//
public void OnClientPostAdminCheck(int client)
{
  if (isLAN || ar_time == 0 || IsFakeClient(client) || !IsClientConnected(client))
    return;

  Played[client] = false;

  char steamId[30];
  GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

  int disconnect_time = g_kvDB.GetNum(steamId, -1);

  if (disconnect_time == -1)
    return;

  int wait_time = disconnect_time + ar_time - GetTime();

  if (wait_time <= 0)
  {
    g_kvDB.DeleteKey(steamId);
  }
  else
  {
    Played[client] = true;
    Join_Timer[client] = CreateTimer(6.0, PlayerJoin, client);
  }

  if (!IsTimeTeleport || Played[client])
  {
    return;
  }

  Attempt[client] = 0;

  CreateTimer(3.5, TimerTeleport, client);
}

public Action TimerTeleport(Handle timer, int client)
{
  if (!IsClientConnected(client) || !IsClientInGame(client) || Played[client] || Attempt[client] > 5) return;
  if (GetClientTeam(client) != TEAM_SURVIVORS || !IsPlayerAlive(client))
  {
    Attempt[client]++;
    CreateTimer(3.5, TimerTeleport, client);
    return;
  }
  TeleportClientTo(client);
  SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
  CreateTimer(5.1, Mortal, client);
  PrintToChat(client, "%t", "You are temporarily invulnerable!");
}

public Action Mortal(Handle timer, int client)
{
  if (IsClientInGame(client) && GetClientTeam(client) == TEAM_SURVIVORS && IsPlayerAlive(client))
  {
    SetEntProp(client, Prop_Data, "m_takedamage", 2, 1);
    PrintToChat(client, "%t", "You are no longer invulnerable!");
  }
}

void TeleportClientTo(int client)
{
  for (int i = 1; i < MaxClients; i++)
  {
    if (i != client && IsClientInGame(i) && GetClientTeam(i) == TEAM_SURVIVORS && IsPlayerAlive(i) && IsNotFalling(i))
    {
      float pos[3];
      GetClientAbsOrigin(i, pos);
      TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
      break;
    }
  }
}

bool IsNotFalling(int i)
{
  return GetEntProp(i, Prop_Send, "m_isHangingFromLedge") == 0 && GetEntProp(i, Prop_Send, "m_isFallingFromLedge") == 0 && (GetEntPropFloat(i, Prop_Send, "m_flFallVelocity") == 0 || GetEntPropFloat(i, Prop_Send, "m_flFallVelocity") < -100);
}

public Action PlayerJoin(Handle timer, int client)
{
  if (client > 0 && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == TEAM_SURVIVORS && IsPlayerAlive(client))
  {
    if (Played[client])
    {
      ChangeClientTeam(client, TEAM_SPECTATORS);
    }
    Join_Timer[client] = null;
  }
  else
  {
    Join_Timer[client] = null;
  }
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
  for (int i=1; i<=MaxClients; i++)
  {
    if (IsValidEntity(i))
    {
      if (IsClientInGame(i))
      {
        if (GetClientTeam(i) == TEAM_SURVIVORS && !IsPlayerAlive(i))
        {
          CreateTimer(0.5, Respawn, i);
        }
      }
    }

    Played[i] = false;
  }

  for (int i=1; i<=MaxClients; i++)
  {
    if (IsValidEntity(i))
    {
      if (IsClientInGame(i))
      {
        if (GetClientTeam(i) == TEAM_SURVIVORS && IsPlayerAlive(i))
        {
          CreateTimer(1.0, TeleportFix, i);
        }
      }
    }
  }

  g_bBlockJoinCommand = false;
  IsTimeTeleport = false;

  CreateTimer(60.5, TimeToTeleportNewClients);
  CreateTimer(70.5, BotsOn);
}

public Action Respawn(Handle timer, int client)
{
  if (!IsClientInGame(client) || GetClientTeam(client) != 2 || IsPlayerAlive(client)) return;
  SDKCall(hRoundRespawn, client);
}

public Action TeleportFix(Handle timer, int client)
{
  if (!IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client) || IsTimeTeleport) return;
  char map[32];
  float pos[3];
  GetCurrentMap(map, sizeof(map));
  if (StrEqual(map, "l4d_yama_3"))
  {
    pos[0] = 356.8;
    pos[1] = -6478.3;
    pos[2] = -256.5;

    TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
  }
  else if (StrEqual(map, "c12m1_hilltop"))
  {
    pos[0] = -7929.343750;
    pos[1] = -15099.072265;
    pos[2] = 283.059387;

    TeleportEntity(client, pos, NULL_VECTOR, NULL_VECTOR);
  }
  else return;
}

public Action BotsOn(Handle timer)
{
  if (!isBotsOn)
  {
    isBotsOn = true;
  }
}

public Action TimeToTeleportNewClients(Handle timer, int client)
{
  IsTimeTeleport = true;

  return Plugin_Stop;
}

public Action Tweak(int client, int args)
{
  TweakSettings1();
}

stock void TweakSettings1()
{
  ConVar hMaxSurvivorsLimitCvar = FindConVar("survivor_limit");
  hMaxSurvivorsLimitCvar.SetBounds(ConVarBound_Lower, true, 4.0);
  hMaxSurvivorsLimitCvar.SetBounds(ConVarBound_Upper, true, 25.0);
  hMaxSurvivorsLimitCvar.SetInt(hMaxSurvivors.IntValue);
  FindConVar("z_spawn_flow_limit").IntValue = 50000; // allow spawning bots at any time
  FindConVar("z_max_player_zombies").SetBounds(ConVarBound_Upper, true, 5.0);
}

public Action Coord(int client, int args)
{
  if (!client) return Plugin_Continue;

  if(!SetTeleportEndPoint(client))
  {
    ReplyToCommand(client, "[SM] Coordinate Error");
    return Plugin_Continue;
  }

  g_Vpos[2] -= 8.0;

  PrintToChat(client, "\x04Coordinates: \x03pos[0] = %f; pos[1] = %f; pos[2] = %f;", g_Vpos[0], g_Vpos[1], g_Vpos[2]);

  return Plugin_Continue;
}

bool SetTeleportEndPoint(int client)
{
  float vAngles[3];
  float vOrigin[3];
  float vBuffer[3];
  float vStart[3];
  float Distance;

  GetClientEyePosition(client,vOrigin);
  GetClientEyeAngles(client, vAngles);

  //get endpoint for teleport
  Handle trace = TR_TraceRayFilterEx(vOrigin, vAngles, MASK_SHOT, RayType_Infinite, Player_TraceFilter);

  if(TR_DidHit(trace))
  {
    TR_GetEndPosition(vStart, trace);
    GetVectorDistance(vOrigin, vStart, false);
    Distance = -35.0;
    GetAngleVectors(vAngles, vBuffer, NULL_VECTOR, NULL_VECTOR);
    g_Vpos[0] = vStart[0] + (vBuffer[0]*Distance);
    g_Vpos[1] = vStart[1] + (vBuffer[1]*Distance);
    g_Vpos[2] = vStart[2] + (vBuffer[2]*Distance);
  }
  else
  {
    delete trace;
    return false;
  }
  delete trace;
  return true;
}

public bool Player_TraceFilter(int entity, int contentsMask)
{
  return entity > MaxClients || !entity;
}

//************************************************//

public Action JoinTeam(int client, int args)
{
  if (g_bBlockJoinCommand)
    return Plugin_Handled;

  if (!IsClientInGame(client))
    return Plugin_Handled;

  if (GetClientTeam(client) == TEAM_INFECTED && IsAlive(client))
    return Plugin_Handled;

  // Anti reconnect part
  if (GetClientTeam(client) == TEAM_SURVIVORS)
  {
    if (IsPlayerAlive(client))
    {
      PrintHintText(client, "You are allready joined the Survivor team");
    }
    else
    {
      PrintHintText(client, "Please wait to be revived or rescued");
    }
  }
  else if (IsClientIdle(client))
  {
    PrintHintText(client, "You are now idle. Press mouse to play as survivor");
  }
  else
  {
    if (TotalFreeBots() == 0)
    {
      ChangeClientTeam(client, TEAM_SURVIVORS);
      CreateTimer(1.0, Timer_AutoJoinTeam, client);
    }
    else
      TakeOverBot(client, false);
  }
  return Plugin_Handled;
}
////////////////////////////////////
// Events
////////////////////////////////////
public Action evtRoundStartAndItemPickup(Event event, const char[] name, bool dontBroadcast)
{
  if (!gbFirstItemPickedUp)
  {
    // alternative to round start...
    if (timer_SpecCheck == null)
      timer_SpecCheck = CreateTimer(15.0, Timer_SpecCheck, _, TIMER_REPEAT);

    if (isBotsOff) CreateTimer(40.3, TimerBotsOn, _);  // если боты в команде выживших отключены

    gbFirstItemPickedUp = true;
  }
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (!gbPlayerPickedUpFirstItem[client] && !IsFakeClient(client))
  {
    // force setting client cvars here...
    gbPlayerPickedUpFirstItem[client] = true;
    gbPlayedAsSurvivorBefore[client] = true;
  }
}

public Action evtPlayerActivate(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));

  if (client)
  {
    if ((GetClientTeam(client) != TEAM_INFECTED) && (GetClientTeam(client) != TEAM_SURVIVORS) && !IsFakeClient(client) && !IsClientIdle(client))
      CreateTimer(1.0 * GetRandomFloat(5.5, 10.5), Timer_AutoJoinTeam, client);
  }
}

public Action evtPlayerLeftStart(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (client)
  {
    if (IsClientConnected(client) && IsClientInGame(client))
    {
      if (GetClientTeam(client)==TEAM_SURVIVORS)
        gbPlayedAsSurvivorBefore[client] = true;
    }
  }
}

public Action evtPlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));

  if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
  {
    CreateTimer(0.5, ClientInServer, client);
    Join_Timer[client] = CreateTimer(5.0, PlayerJoin, client);
  }

  if (Played[client])
  {
    char steamId[30];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    int disconnect_time = g_kvDB.GetNum(steamId, -1);

    if (disconnect_time == -1)
      Played[client] = false;

    int wait_time = disconnect_time + ar_time - GetTime();

    if (wait_time <= 0)
    {
      g_kvDB.DeleteKey(steamId);
      Played[client] = false;
    }
    else
    {
      Played[client] = true;
    }
  }
}

public Action ClientInServer(Handle timer, int client)
{
  if (client > 0 && IsClientInGame(client) && !IsFakeClient(client))
  {
    if (GetClientTeam(client) == TEAM_SURVIVORS)
    {
      if (!Played[client])
      {
        if (!IsPlayerAlive(client))
        {
          SDKCall(hRoundRespawn, client);
        }

        if (IsTimeTeleport) //PerformTeleport(client, target);
        {
          SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
          CreateTimer(5.1, Mortal, client);

          int target = GetRandomClient(client);

          if (target > 0)
          {
            float teleportOrigin[3];
            GetClientAbsOrigin(target, teleportOrigin);
            TeleportEntity(client, teleportOrigin, NULL_VECTOR, NULL_VECTOR);
            return;
          }

          for (int i = 1; i <= MaxClients; i++)
          {
            if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVORS) && IsAlive(i) && IsNotFalling(i) && i != client)
            {
              // get the position coordinates of any active alive player
              float teleportOrigin[3];
              GetClientAbsOrigin(i, teleportOrigin);
              TeleportEntity(client, teleportOrigin, NULL_VECTOR, NULL_VECTOR);
              break;
            }
          }
        }
        else CreateTimer(1.0, TeleportFix, client);
      }
      else
      {
        char steamId[30];
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

        int disconnect_time = g_kvDB.GetNum(steamId, -1);

        if (disconnect_time == -1)
          Played[client] = false;

        int wait_time = disconnect_time + ar_time - GetTime();

        if (wait_time <= 0)
        {
          g_kvDB.DeleteKey(steamId);
          Played[client] = false;
        }
        else
        {
          Played[client] = true;
        }

        if (IsPlayerAlive(client))
        {
          if (IsTimeTeleport)
          {
            SetEntProp(client, Prop_Data, "m_takedamage", 0, 1);
            CreateTimer(5.1, Mortal, client);

            int target = GetRandomClient(client);

            if (target > 0)
            {
              float teleportOrigin[3];
              GetClientAbsOrigin(target, teleportOrigin);
              TeleportEntity(client, teleportOrigin, NULL_VECTOR, NULL_VECTOR);
              return;
            }

            for (int i = 1; i <= MaxClients; i++)
            {
              if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVORS) && IsAlive(i) && IsNotFalling(i) && i != client)
              {
                // get the position coordinates of any active alive player
                float teleportOrigin[3];
                GetClientAbsOrigin(i, teleportOrigin);
                TeleportEntity(client, teleportOrigin, NULL_VECTOR, NULL_VECTOR);
                break;
              }
            }
          }
          else CreateTimer(1.0, TeleportFix, client);
        }
      }
    }
  }
}

public Action evtPlayerReplacedBot(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("player"));
  if (!client) return;
  if (GetClientTeam(client) != TEAM_SURVIVORS || IsFakeClient(client)) return;

  if (!gbPlayedAsSurvivorBefore[client])
  {
    gbPlayedAsSurvivorBefore[client] = true;
    giIdleTicks[client] = 0;
  }
}

public Action evtSurvivorRescued(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("victim"));
  if (client)
  {
    StripWeapons(client);
    GiveWeapon(client);
  }
}

public Action evtFinaleVehicleLeaving(Event event, const char[] name, bool dontBroadcast)
{
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i) && IsClientInGame(i))
    {
      if ((GetClientTeam(i) == TEAM_SURVIVORS) && IsAlive(i))
      {
        SetEntProp(i, Prop_Data, "m_takedamage", DAMAGE_EVENTS_ONLY, 1);
        float newOrigin[3] = { 0.0, 0.0, 0.0 };
        TeleportEntity(i, newOrigin, NULL_VECTOR, NULL_VECTOR);
        SetEntProp(i, Prop_Data, "m_takedamage", DAMAGE_YES, 1);
      }
    }
  }
  StopTimers();
  gbVehicleLeaving = true;
}

public Action evtMissionLost(Event event, const char[] name, bool dontBroadcast)
{
  g_bBlockJoinCommand = true;
  gbFirstItemPickedUp = false;
}

public Action evtBotReplacedPlayer(Event event, const char[] name, bool dontBroadcast)
{
  int bot = GetClientOfUserId(event.GetInt("bot"));
  if (GetClientTeam(bot) == TEAM_SURVIVORS)
  {
    //if (isBotsOn && isBotsOff) CreateTimer(0.3, TimerBotsOn, bot);
    CreateTimer(DELAY_KICK_NONEEDBOT, Timer_KickNoNeededBot, bot);
  }
}
////////////////////////////////////
// timers
////////////////////////////////////
public Action Timer_SpecCheck(Handle timer)
{
  if (gbVehicleLeaving) return Plugin_Stop;

  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i) && IsClientInGame(i))
    {
      if ((GetClientTeam(i) == TEAM_SPECTATORS) && !IsFakeClient(i))
      {
        if (!IsClientIdle(i))
        {
          PrintHintText(i, "%N, press USE (E) to join the Survivor Team", i);
        }
        switch(hKickIdlers.IntValue)
        {
          case 0: {}
          case 1:
          {
            if (GetUserFlagBits(i) == 0)
            {
              giIdleTicks[i]++;
              if (giIdleTicks[i] == 40)
                KickClient(i, "Player idle longer than 10 min.");
            }
          }
          case 2:
          {
            giIdleTicks[i]++;
            if (GetUserFlagBits(i) == 0)
            {
              if (giIdleTicks[i] == 40)
                KickClient(i, "Player idle longer than 10 min.");
            }
            else
            {
              if (giIdleTicks[i] == 240)
                KickClient(i, "Admin idle longer than 60 min.");
            }
          }
        }
      }
    }
  }
  return Plugin_Continue;
}

public Action Timer_AutoJoinTeam(Handle timer, int client)
{
  if (!IsClientInGame(client))
  {
    return Plugin_Stop;
  }
  else
  {
    if (GetClientTeam(client) == TEAM_SURVIVORS)
      return Plugin_Stop;

    if (IsClientIdle(client))
      return Plugin_Stop;

    JoinTeam(client, 0);
  }
  return Plugin_Continue;
}

public Action TimerBotsOn(Handle timer)
{
  char CurrentMap[64];
  GetCurrentMap(CurrentMap, sizeof(CurrentMap));
  if (StrEqual(CurrentMap, "c6m3_port", false) && TotalSurvivors() > 5)  return Plugin_Handled;
  if (!isBotsOff) return Plugin_Handled; // if the bots in the surviving team are on, kill the timer

  // return the bots to the surviving team
  cvar_no_bots_survivors.SetInt(0);
  isBotsOff = false;

  return Plugin_Handled;
}

public Action Timer_KickNoNeededBot(Handle timer, int bot)
{
  if ((TotalSurvivors() <= 4))
    return Plugin_Handled;

  if (IsClientConnected(bot) && IsClientInGame(bot))
  {
    if (GetClientTeam(bot) == TEAM_INFECTED)
      return Plugin_Handled;

    char BotName[100];
    GetClientName(bot, BotName, sizeof(BotName));
    if (StrEqual(BotName, "FakeClient", true))
      return Plugin_Handled;

    if (!HasIdlePlayer(bot))
    {
      StripWeapons(bot);
      KickClient(bot, "Kicking No Needed Bot");
    }
  }

  return Plugin_Handled;
}

public Action Timer_KickFakeBot(Handle timer, int fakeclient)
{
  if (IsClientConnected(fakeclient))
  {
    KickClient(fakeclient, "Kicking FakeClient");
    return Plugin_Stop;
  }
  return Plugin_Continue;
}
////////////////////////////////////
// stocks
////////////////////////////////////
stock void TakeOverBot(int client, bool completely)
{
  if (!IsClientInGame(client)) return;
  if (GetClientTeam(client) == TEAM_SURVIVORS) return;
  if (IsFakeClient(client)) return;

  int bot = FindBotToTakeOver();
  if (bot==0)
  {
    PrintHintText(client, "No survivor bots to take over.");
    return;
  }

  static Handle hSetHumanSpec;
  if (hSetHumanSpec == null)
  {
    GameData hGameConf;
    hGameConf = new GameData("l4dmultislots");

    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "SetHumanSpec");
    PrepSDKCall_AddParameter(SDKType_CBasePlayer, SDKPass_Pointer);
    hSetHumanSpec = EndPrepSDKCall();
  }

  static Handle hTakeOverBot;
  if (hTakeOverBot == null)
  {
    GameData hGameConf;
    hGameConf = new GameData("l4dmultislots");

    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(hGameConf, SDKConf_Signature, "TakeOverBot");
    PrepSDKCall_AddParameter(SDKType_Bool, SDKPass_Plain);
    hTakeOverBot = EndPrepSDKCall();
  }

  if (completely)
  {
    SDKCall(hSetHumanSpec, bot, client);
    SDKCall(hTakeOverBot, client, true);
  }
  else
  {
    SDKCall(hSetHumanSpec, bot, client);
    SetEntProp(client, Prop_Send, "m_iObserverMode", 5);
  }

  return;
}

stock int FindBotToTakeOver()
{
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i))
    {
      if (IsClientInGame(i))
      {
        if (IsFakeClient(i) && GetClientTeam(i)==TEAM_SURVIVORS && IsAlive(i) && !HasIdlePlayer(i))
          return i;
      }
    }
  }
  return 0;
}

stock void BypassAndExecuteCommand(int client, const char[] strCommand, const char[] strParam1)
{
  int flags = GetCommandFlags(strCommand);
  SetCommandFlags(strCommand, flags & ~FCVAR_CHEAT);
  FakeClientCommand(client, "%s %s", strCommand, strParam1);
  SetCommandFlags(strCommand, flags);
}

stock void StripWeapons(int client) // strip all items from client
{
  int itemIdx;
  for (int x = 0; x <= 3; x++)
  {
    if ((itemIdx = GetPlayerWeaponSlot(client, x)) != -1)
    {
      RemovePlayerItem(client, itemIdx);
      RemoveEdict(itemIdx);
    }
  }
}

stock void GiveWeapon(int client) // give client random weapon
{
  switch(GetRandomInt(0,6))
  {
    case 0: BypassAndExecuteCommand(client, "give", "pistol");
    case 1: BypassAndExecuteCommand(client, "give", "pistol_magnum");
    case 2: BypassAndExecuteCommand(client, "give", "pistol");
    case 3: BypassAndExecuteCommand(client, "give", "pistol_magnum");
    case 4: BypassAndExecuteCommand(client, "give", "pistol");
    case 5: BypassAndExecuteCommand(client, "give", "pistol");
    case 6: BypassAndExecuteCommand(client, "give", "pistol_magnum");
  }
  BypassAndExecuteCommand(client, "give", "ammo");
}

stock int TotalSurvivors() // total bots, including players
{
  int survivors = 0;
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i))
    {
      if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVORS))
        survivors++;
    }
  }
  return survivors;
}

stock int TotalRealPlayers()
{
  int players = 0;
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i))
    {
      if (IsClientInGame(i))
      {
        if (!IsFakeClient(i))
          players++;
      }
    }
  }
  return players;
}

stock int TotalFreeBots() // total bots (excl. IDLE players)
{
  int bots = 0;
  for(int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i) && IsClientInGame(i))
    {
      if (IsFakeClient(i) && GetClientTeam(i) == TEAM_SURVIVORS)
      {
        if (!HasIdlePlayer(i))
          bots++;
      }
    }
  }
  return bots;
}

stock bool HasIdlePlayer(int bot)
{
  if (IsValidEntity(bot))
  {
    char sNetClass[12];
    GetEntityNetClass(bot, sNetClass, sizeof(sNetClass));

    if (strcmp(sNetClass, "SurvivorBot") == 0)
    {
      if (!GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"))
        return false;

      int client = GetClientOfUserId(GetEntProp(bot, Prop_Send, "m_humanSpectatorUserID"));
      if (client)
      {
        // Do not count bots
        // Do not count 3rd person view players
        if (IsClientInGame(client) && !IsFakeClient(client) && (GetClientTeam(client) != TEAM_SURVIVORS))
          return true;
      }
      else return false;
    }
  }
  return false;
}

stock void StopTimers()
{
  if (timer_SpecCheck != null)
  {
    KillTimer(timer_SpecCheck);
    timer_SpecCheck = null;
  }
}
////////////////////////////////////
// bools
////////////////////////////////////

bool SpawnFakeClientAndTeleport()
{
  int ClientsCount = GetClientCount(false);

  int bots = 0;
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsValidSurvivorBot(i))
    {
      bots++;
    }
  }

  bool fakeclientKicked = false;

  // create fakeclient
  int fakeclient = 0;

  if (ClientsCount < 31 && bots < 3)
  {
    fakeclient = CreateFakeClient("FakeClient");
  }

  // if entity is valid
  if (fakeclient != 0)
  {
    // move into survivor team
    ChangeClientTeam(fakeclient, TEAM_SURVIVORS);

    // check if entity classname is survivorbot
    if (DispatchKeyValue(fakeclient, "classname", "survivorbot") == true)
    {
      // spawn the client
      if (DispatchSpawn(fakeclient) == true)
      {
        // teleport client to the position of any active alive player
        for (int i = 1; i <= MaxClients; i++)
        {
          if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVORS) && !IsFakeClient(i) && IsAlive(i) && i != fakeclient)
          {
            // get the position coordinates of any active alive player
            float teleportOrigin[3];
            GetClientAbsOrigin(i, teleportOrigin);
            TeleportEntity(fakeclient, teleportOrigin, NULL_VECTOR, NULL_VECTOR);
            break;
          }
        }

        StripWeapons(fakeclient);
        BypassAndExecuteCommand(fakeclient, "give", "pistol");

        // kick the fake client to make the bot take over
        CreateTimer(DELAY_KICK_FAKECLIENT, Timer_KickFakeBot, fakeclient, TIMER_REPEAT);
        fakeclientKicked = true;
      }
    }
    // if something went wrong, kick the created FakeClient
    if (fakeclientKicked == false)
      KickClient(fakeclient, "Kicking FakeClient");
  }
  return fakeclientKicked;
}

bool IsClientIdle(int client)
{
  char sNetClass[12];

  for(int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i) && IsClientInGame(i))
    {
      if ((GetClientTeam(i) == TEAM_SURVIVORS) && IsPlayerAlive(i))
      {
        if (IsFakeClient(i))
        {
          GetEntityNetClass(i, sNetClass, sizeof(sNetClass));
          if (strcmp(sNetClass, "SurvivorBot") == 0)
          {
            if (GetClientOfUserId(GetEntProp(i, Prop_Send, "m_humanSpectatorUserID")) == client)
              return true;
          }
        }
      }
    }
  }
  return false;
}

bool IsAlive(int client)
{
  if (!GetEntProp(client, Prop_Send, "m_lifeState"))
    return true;

  return false;
}

stock bool IsValidSurvivorBot(int client)
{
  if (!client) return false;
  if (!IsClientInGame(client)) return false;
  if (!IsFakeClient(client)) return false;
  if (GetClientTeam(client) != TEAM_SURVIVORS) return false;
  return true;
}

stock int GetRandomClient(int client)
{
  int count = 0;
  int[] players = new int[MaxClients];
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientInGame(i) && (GetClientTeam(i) == TEAM_SURVIVORS) && IsAlive(i) && IsNotFalling(i) && i != client)
    {
      players[count++] = i;
    }
  }
  return count > 0 ? players[GetRandomInt(0, count - 1)] : -1;
}
//************************************************//
//********     ANTI RECONNECT PART    ************//
//************************************************//

public Action Event_PlayerDisconnect(Event event, const char[] name, bool dontBroadcast)
{
  char reason[128];
  int client = GetClientOfUserId(event.GetInt("userid"));

  if (!client)
    return;

  Played[client] = false;

  event.GetString("reason", reason, 128);

  if (StrEqual(reason, "Nick change is prohibited!") || StrEqual(reason, "Name change is not allowed") || StrEqual(reason, "Disconnect by user.") || !ar_disconnect_by_user_only)
  {
    if (isLAN || ar_time == 0 || IsFakeClient(client))
      return;

    if (GetUserFlagBits(client) && ar_admin_immunity)
      return;

    char steamId[30];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));

    g_kvDB.SetNum(steamId, GetTime());
  }
}

public void OnCVarChange(ConVar convar, const char[] oldValue, const char[] newValue)
{
  GetCVars();
}

public void OnConfigsExecuted()
{
  GetCVars();
}

public void GetCVars()
{
  isLAN = cvar_lan.BoolValue;
  ar_time = cvar_ar_time.IntValue;
  ar_disconnect_by_user_only = cvar_ar_disconnect_by_user_only.BoolValue;
  ar_admin_immunity = cvar_ar_admin_immunity.BoolValue;
}

public Action Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
  g_bBlockJoinCommand = true;

  // if the real players on the server are less than or equal to 7 or the bots in the surviving team are turned off, kill the timer
  if ((TotalRealPlayers() <= 7) || isBotsOff || g_iMapFix)
    return Plugin_Handled;

  // remove bots in the surviving team
  cvar_no_bots_survivors.SetInt(1);
  // bots are off
  isBotsOff = true;

  return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3])
{
  if (!IsValidPlayer(client)) return;
  if (g_bBlockJoinCommand) return;

  if (buttons & IN_USE)
  {
    JoinTeam(client, 0);
  }
}

public Action Client_JoinTeam(int client, const char[] command, int argc)
{
  if (!IsValidPlayer(client)) return Plugin_Handled;
  if (g_bBlockJoinCommand) return Plugin_Handled;

  JoinTeam(client, 0);

  return Plugin_Handled;
}

public bool IsValidPlayer(int client)
{
  if (client == 0)
    return false;

  if (!IsClientConnected(client))
    return false;

  if (!IsClientInGame(client))
    return false;

  if (IsFakeClient(client))
    return false;

  if (GetClientTeam(client) != TEAM_SPECTATORS)
    return false;

  return true;
}
