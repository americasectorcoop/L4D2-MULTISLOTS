// based on http://forums.alliedmods.net/showthread.php?p=1349430
// � http://forums.alliedmods.net/member.php?u=96768

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <left4dhooks>

#if SOURCEMOD_V_MINOR < 7
 #error Old version sourcemod!
#endif
#pragma newdecls required

#define PLUGIN_NAME "L4D2 Afk and keep item fix"
#define PLUGIN_AUTHOR "Jonny"
#define PLUGIN_DESCRIPTION "L4D2 afk and keep item fix"
#define PLUGIN_VERSION "1.0.0"
#define PLUGIN_URL ""

#define MAX_LINE_WIDTH 64
#define MAX_STEAM_LENGTH 32

#define CHECK_TIME 20.0

#define DBUG 0

#define PATCH "logs\\l4d2_keep_item_fix.log"

public Plugin myinfo =
{
  name = PLUGIN_NAME,
  author = PLUGIN_AUTHOR,
  description = PLUGIN_DESCRIPTION,
  version = PLUGIN_VERSION,
  url = PLUGIN_URL
}

char slotPrimary[MAXPLAYERS + 1][2][MAX_LINE_WIDTH];
char slotSecondary[MAXPLAYERS + 1][2][MAX_LINE_WIDTH];
char slotThrowable[MAXPLAYERS + 1][2][MAX_LINE_WIDTH];
char slotMedkit[MAXPLAYERS + 1][2][MAX_LINE_WIDTH];
char slotPills[MAXPLAYERS + 1][2][MAX_LINE_WIDTH];
int priAmmo[MAXPLAYERS + 1][2];
int priClip[MAXPLAYERS + 1][2];
int priUpgrade[MAXPLAYERS + 1][2];
int priUpgrAmmo[MAXPLAYERS + 1][2];
int slotHealth[MAXPLAYERS + 1];
char slotAuth[MAXPLAYERS + 1][MAX_STEAM_LENGTH];

#if DBUG
char LOG[256];
#endif

float g_iTempHP[MAXPLAYERS + 1];
int g_iPermHP[MAXPLAYERS + 1];
int g_iIncaps[MAXPLAYERS + 1];
bool g_bGoToAFK[MAXPLAYERS + 1];
bool g_bWaitAFK[MAXPLAYERS + 1];

bool g_bPlayerDeath[MAXPLAYERS+1];
bool g_bPlayerTake[MAXPLAYERS+1];

int g_iRounds;
bool g_bFirstMap;
bool g_bIsRoundStarted;

float g_iCvarSpecT = 55.0;
static float g_fButtonTime[MAXPLAYERS+1];
static bool g_bTempBlock[MAXPLAYERS+1];
static int ammoOffset;
bool g_bMapTranslition;

GameData gGameConf = null;
Handle hRoundRevive = null;

ConVar g_cvar_enable;
ConVar g_cvar_check_steamid;
ConVar g_cvar_clear_items;
ConVar g_cvar_give_items;

public void OnPluginStart()
{
  LoadTranslations("l4d2_afk.phrases");
  
#if DBUG
  BuildPath(Path_SM, LOG, sizeof(LOG), PATCH);
#endif
  
  char temp[12];
  
  FloatToString(g_iCvarSpecT, temp, sizeof(temp));
  CreateConVar("hardmod_kif_spec_time", temp, "Time before idle player will be moved to spectator in seconds.").AddChangeHook(convar_AfkSpecTime);
  
  g_cvar_enable = CreateConVar("hardmod_kif", "1", "", 0);
  g_cvar_check_steamid = CreateConVar("hardmod_kif_auth_check", "1", "", 0);
  g_cvar_clear_items = CreateConVar("hardmod_kif_remove_items", "0", "", 0);
  g_cvar_give_items = CreateConVar("hardmod_give_items", "1", "", 0);


  // HookEvent("defibrillator_used", Event_KIFDefibrillatorUsed, EventHookMode:1);
	// HookEvent("player_spawn", Event_KIFPlayerSpawn, EventHookMode:1);
	// HookEvent("player_transitioned", Event_KIFPlayerTransitioned, EventHookMode:1);
  
  HookEvent("finale_win", Event_FinalWin); // si existe, 
  HookEvent("map_transition", Event_MapTransition, EventHookMode_Pre);
  HookEvent("player_death", Event_PlayerDeath);
  HookEvent("player_say",	Event_PlayerSay);
  HookEvent("player_team", Event_PlayerTeam);
  HookEvent("round_start", Event_RoundStart, EventHookMode_PostNoCopy);
  HookEvent("round_end", Event_RoundEnd);
  HookEvent("survivor_rescued", Event_SurvivorRescued, EventHookMode_Pre);
  
  ammoOffset = FindSendPropInfo("CTerrorPlayer", "m_iAmmo");
  
  RegAdminCmd("keep_save", Command_Save, ADMFLAG_CHEATS, "keep_save");
  RegAdminCmd("keep_load", Command_Load, ADMFLAG_CHEATS, "keep_load");
  RegAdminCmd("keep_clear", Command_Clear, ADMFLAG_CHEATS, "keep_clear");
  RegAdminCmd("keep_load_weapons", Command_Load_Weapons, ADMFLAG_CHEATS, "keep_load_weapons <target>");
  RegAdminCmd("keep_save_weapons", Command_Save_Weapons, ADMFLAG_CHEATS, "keep_save_weapons <target>");
  
  RegConsoleCmd("keep_read", Command_Read);
  RegConsoleCmd("keep_current", Command_Current);
  
  RegConsoleCmd("go_away_from_keyboard", Cmd_AFK);
  RegConsoleCmd("sm_afk", Command_AFK);
  RegConsoleCmd("sm_idle", Command_AFK);
  RegConsoleCmd("sm_spectate", Command_AFK);
  
  gGameConf = new GameData("l4drevive");
  if (gGameConf != null)
  {
    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(gGameConf, SDKConf_Signature, "CTerrorPlayer_OnRevived");
    hRoundRevive = EndPrepSDKCall();
    if (hRoundRevive == null)
      SetFailState("Unable to find the \"CTerrorPlayer::OnRevived(void)\" signature, check the file version!");
    }
  else
    SetFailState("could not find gamedata file at addons/sourcemod/gamedata/l4drevive.txt , you FAILED AT INSTALLING");
  
  CreateTimer(0.2, TimerMapName);
  CreateTimer(CHECK_TIME, SAM_t_CheckIdles, _, TIMER_REPEAT);
}

public void OnClientPostAdminCheck(int client)
{
  if (IsFakeClient(client))
    return;
  
  g_bGoToAFK[client] = false;
  g_bWaitAFK[client] = false;

  if (GetClientTime(client) <= 60)
    ClearClientDataFinal(client);
  
  if (!g_bFirstMap)
    CreateTimer(1.2, CycleRetryRestore, client);
  else
  {
    ClearClientData(client);
    CreateTimer(1.5, CycleRetryRestore, client);
  }
}

public Action CycleRetryRestore(Handle timer, any client)
{
  if (!IsClientInGame(client)) return;
  if (GetClientTeam(client) != 2 || !IsPlayerAlive(client))
  {
    CreateTimer(1.0, CycleRetryRestore, client);
    return;
  }
  RestoreClientData(client, false);
}

public Action Command_Save(int client, int args)
{
  SaveClients();
}

public Action Command_Load(int client ,int args)
{
  for (int i=1; i<=MaxClients; i++)
    RestoreClientData(i, false);
}

public Action Command_Clear(int client ,int args)
{
  for (int i=1; i<=MaxClients; i++) ClearClientData(i);
}

public Action Command_Read(int client ,int args)
{
  if (client == 0) return Plugin_Handled;
  int slot;
  if (g_bGoToAFK[client]) slot = 1;
  else slot = 0;
  PrintToChat(client, "\x05Primary = [\x04%s\x05] \x01|\x05 Secondary = [\x04%s\x05]", slotPrimary[client][slot], slotSecondary[client][slot]);
  PrintToChat(client, "\x05ammo[\x04%d\x05] \x01|\x05 clip[\x04%d\x05] \x01|\x05 upgrade[\x04%d\x05] \x01|\x05 upgradeammo[\x04%d\x05]", priAmmo[client][slot], priClip[client][slot], priUpgrade[client][slot], priUpgrAmmo[client][slot]);
  PrintToChat(client, "\x05Throwable = [\x04%s\x05]", slotThrowable[client][slot]);
  if (slot == 0)
    PrintToChat(client, "\x05Medkit = [\x04%s\x05] \x01|\x05 Pills = [\x04%s\x05] \x01|\x05 \x05Health = [\x04%d\x05]", slotMedkit[client][slot], slotPills[client][slot], slotHealth[client]);
  else
  {
    bool bw = false;
    if (g_iIncaps[client] == FindConVar("survivor_max_incapacitated_count").IntValue) bw = true;
    
    PrintToChat(client, "\x05Medkit = [\x04%s\x05] \x01|\x05 Pills = [\x04%s\x05]", slotMedkit[client][slot], slotPills[client][slot]);
    if (bw) PrintToChat(client, "\x05Permanent Health = [\x04%d\x05] \x01|\x05 Temp health = [\x04%.0f\x05] \x01|\x05 B&W = [\x01Yes\x05]", g_iPermHP[client], g_iTempHP[client]);
    else PrintToChat(client, "\x05Permanent Health = [\x04%d\x05] \x01|\x05 Temp health = [\x04%.0f\x05] \x01|\x05 B&W = [\x04No\x05]", g_iPermHP[client], g_iTempHP[client]);
  }
  return Plugin_Handled;
}

public Action Command_Current(int client ,int args)
{
  if (GetPlayerWeaponSlot(client, 0) != -1)
  {
    char CurrentWeapon[64];
    GetEdictClassname(GetPlayerWeaponSlot(client, 0), CurrentWeapon, sizeof(CurrentWeapon));
    PrintToChat(client, "\x05Primary Weapon = %s", CurrentWeapon);
  }
}

public void OnMapStart()
{
  g_iRounds = 1;

  if (g_cvar_enable.IntValue < 1) return;
  
  CreateTimer(0.2, TimerMapName);
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
  if (!g_bIsRoundStarted)
    return;
  
  g_bMapTranslition = true;
  g_iRounds++;
  
  int i = 1;
  while (i <= MaxClients)
  {
    if (IsClientInGame(i) && !IsFakeClient(i))
      SetEngineTime(i);
    
    i += 1;
  }
  return;
}

public Action Event_FinalWin(Event event, const char[] name, bool dontBroadcast)
{
  for (int i = 1; i <= MaxClients; i++)
    ClearClientDataFinal(i);
}

public Action TimerMapName(Handle timer, any client)
{
  GetCurrentMapName();
  return Plugin_Stop;
}

public void GetCurrentMapName()
{
  if (L4D_IsFirstMapInScenario())
    g_bFirstMap = true;
  else
    g_bFirstMap = false;
}

public void ClearPlayerWeapons(int client)
{
  if (!IsValidClient(client)) return;
  if (IsClientInGame(client))
  {
    if (GetClientTeam(client) == 2 && IsPlayerAlive(client))
    {
      for (int i = 0; i < 5; i++)
      {
        if (GetPlayerWeaponSlot(client, i) > -1)
          RemovePlayerItem(client, GetPlayerWeaponSlot(client, i));
      }
      CheatCmd(client, "give", "pistol");
    }
  }
}

public Action Event_MapTransition(Event event, const char[] name, bool dontBroadcast)
{
  g_bMapTranslition = true;
  g_bFirstMap = false;
  
  int i = 1;
  while (i <=MaxClients)
  {
    if (IsClientInGame(i))
    {
      if (GetClientTeam(i) == 1)
      {
        if (g_bGoToAFK[i])
        {
        #if DBUG
          LogToFile(LOG, "Игрок %N находился в афк перед сменой карты", i);
        #endif
          CloneSlotState(i);
        }
        else
          ClearClientData(i);
      }
      else if (GetClientTeam(i) == 2)
      {
        if (IsPlayerAlive(i))
        {
          if (IsFakeClient(i))
          {
            CheatCmd(i, "give", "health");
            SetEntPropFloat(i, Prop_Send, "m_healthBufferTime", GetGameTime());
            SetEntPropFloat(i, Prop_Send, "m_healthBuffer", 0.0);
            SetEntProp(i, Prop_Send, "m_currentReviveCount", 0);
            SetEntProp(i, Prop_Send, "m_isGoingToDie", 0);
          }
          else
            SaveClientData(i, true, false);
        }
        else
          ClearClientData(i);
      }
      else
        ClearClientData(i);
    }
    else
      ClearClientData(i);
    
    i += 1;
  }
}

public int CloneSlotState(int client)
{
  if (g_cvar_check_steamid.BoolValue)
  {
    char steamId[MAX_STEAM_LENGTH];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    slotAuth[client] = steamId;
  #if DBUG
    LogToFile(LOG, "Стим ид игрока %N находящегося в афк перед сменой карты <%s>", client, slotAuth[client]);
  #endif
  }
  strcopy(slotPrimary[client][0], 64, slotPrimary[client][1]);
  priAmmo[client][0] = priAmmo[client][1];
  priClip[client][0] = priClip[client][1];
  priUpgrade[client][0] = priUpgrade[client][1];
  priUpgrAmmo[client][0] = priUpgrAmmo[client][1];
  strcopy(slotSecondary[client][0], 64, slotSecondary[client][1]);
  strcopy(slotMedkit[client][0], 64, slotMedkit[client][1]);
  strcopy(slotThrowable[client][0], 64, slotThrowable[client][1]);
  strcopy(slotPills[client][0], 64, slotPills[client][1]);
  slotHealth[client] = 50;
#if DBUG
  LogToFile(LOG, "Вещи игрока %N, находящегося в афк перед сменой карты, перешедшие на следующую карту:", client);
  LogToFile(LOG, "slotPrimary = [%s] | slotSecondary = [%s]", client, slotPrimary[client][0], slotSecondary[client][0]);
  LogToFile(LOG, "ammo[%d] | clip[%d] | upgrade[%d] | upgradeammo[%d]", priAmmo[client][0], priClip[client][0], priUpgrade[client][0], priUpgrAmmo[client][0]);
  LogToFile(LOG, "slotThrowable = [%s] | slotMedkit = [%s] | slotPills = [%s] | slotHealth = [%d]", slotThrowable[client][0], slotMedkit[client][0], slotPills[client][0], slotHealth[client]);
#endif
}

/*public Action Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (!client) return;
  if (GetClientTeam(client) != 2) return;
  ClearPlayerWeapons(client);
  
  if (!g_bPlayerDeath[client])
    CreateTimer(1.6, TimerRestoreClientData, client);
  
  if (!IsFakeClient(client) && GetClientTeam(client) == 2)
    g_fButtonTime[client] = (GetEngineTime() - (g_iCvarSpecT * 0.5));
}

public Action TimerRestoreClientData(Handle timer, any client)
{
  if (IsClientInGame(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client) && !g_bPlayerTake[client])
    RestoreClientData(client, false);
}*/

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{	
  if (!g_cvar_enable.BoolValue) return;
  
  g_bIsRoundStarted = true;
  g_bMapTranslition = false;
  
  CreateTimer(0.5, Timer_Bool);
  
  int i = 1;
  while (i <= MaxClients)
  {
    if (IsValidEntity(i))
    {
      if (IsClientInGame(i))
      {
        g_bGoToAFK[i] = false;
        g_bPlayerTake[i] = false;
        
        if (GetClientTeam(i) == 2 && !IsFakeClient(i))
          CreateTimer(1.0, TimerRetryRestore, i);
      }
    }
    i += 1;
  }
}

public Action TimerRetryRestore(Handle timer, any client)
{
  if (!IsClientInGame(client) || GetClientTeam(client) != 2 || !IsPlayerAlive(client))
    return;
  RestoreClientData(client, false);
}

public void SaveClients()
{
  for (int i=1; i<=MaxClients; i++) SaveClientData(i, false, false);
}

public int SaveClientData(int client, bool remove, bool afk)
{
  if (!IsClientInGame(client) || GetClientTeam(client) != 2 || IsFakeClient(client) || !IsPlayerAlive(client)) return;
  
  int slot;
  
  if (afk)
  {
    slot = 1;
    g_iTempHP[client] = GetSurvivorTempHealth(client);
    g_iPermHP[client] = GetClientHealth(client);
    g_iIncaps[client] = GetEntProp(client, Prop_Send, "m_currentReviveCount");
  }
  else
  {
    slot = 0;
    CheatCmd(client, "give", "health");
    
    SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
    SetEntPropFloat(client, Prop_Send, "m_healthBuffer", 0.0);
    SetEntProp(client, Prop_Send, "m_currentReviveCount", 0);
    SetEntProp(client, Prop_Send, "m_isGoingToDie", 0);
    slotHealth[client] = 100;
  }
  
  if (g_cvar_check_steamid.BoolValue)
  {
    char steamId[MAX_STEAM_LENGTH];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    slotAuth[client] = steamId;
  }
  if (GetPlayerWeaponSlot(client, 0) == -1) slotPrimary[client][slot] = "";
  else
  {
    GetEdictClassname(GetPlayerWeaponSlot(client, 0), slotPrimary[client][slot], MAX_LINE_WIDTH);
    
    if (slotPrimary[client][slot][0] != 0)
    {
      if (afk)
      {
        int entity;
        entity = GetPlayerWeaponSlot(client, 0);
        char weapon[64];
        if (entity > 0) GetEntityClassname(entity, weapon, 64);
        
        if (StrEqual(weapon, "weapon_rifle") || StrEqual(weapon, "weapon_rifle_sg552") || StrEqual(weapon, "weapon_rifle_desert") || 
          StrEqual(weapon, "weapon_rifle_ak47"))
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(12));
        else if (StrEqual(weapon, "weapon_smg") || StrEqual(weapon, "weapon_smg_silenced") || StrEqual(weapon, "weapon_smg_mp5"))
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(20));
        else if (StrEqual(weapon, "weapon_pumpshotgun") || StrEqual(weapon, "weapon_shotgun_chrome"))
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(28));
        else if (StrEqual(weapon, "weapon_autoshotgun") || StrEqual(weapon, "weapon_shotgun_spas"))
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(32));
        else if (StrEqual(weapon, "weapon_hunting_rifle"))
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(36));
        else if (StrEqual(weapon, "weapon_sniper_scout") || StrEqual(weapon, "weapon_sniper_military") || StrEqual(weapon, "weapon_sniper_awp")) 
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(40));
        else if (StrEqual(weapon, "weapon_grenade_launcher"))
          priAmmo[client][slot] = GetEntData(client, ammoOffset+(68));
      }
      else priAmmo[client][slot] = GetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_iExtraPrimaryAmmo");
      priClip[client][slot] = GetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_iClip1");
      priUpgrade[client][slot] = GetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_upgradeBitVec");
      priUpgrAmmo[client][slot] = GetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_nUpgradedPrimaryAmmoLoaded");
    }
  }
  if (GetPlayerWeaponSlot(client, 1) == -1) slotSecondary[client][slot] = "pistol";
  else
  {
    char modelname[128];
    GetEntPropString(GetPlayerWeaponSlot(client, 1), Prop_Data, "m_ModelName", modelname, 128);
    if (StrEqual(modelname, "models/weapons/melee/v_fireaxe.mdl", false)) slotSecondary[client][slot] = "fireaxe";
    else if (StrEqual(modelname, "models/weapons/melee/v_crowbar.mdl", false)) slotSecondary[client][slot] = "crowbar";
    else if (StrEqual(modelname, "models/weapons/melee/v_cricket_bat.mdl", false)) slotSecondary[client][slot] = "cricket_bat";
    else if (StrEqual(modelname, "models/weapons/melee/v_katana.mdl", false)) slotSecondary[client][slot] = "katana";
    else if (StrEqual(modelname, "models/weapons/melee/v_bat.mdl", false)) slotSecondary[client][slot] = "baseball_bat";
    else if (StrEqual(modelname, "models/v_models/v_knife_t.mdl", false)) slotSecondary[client][slot] = "knife";
    else if (StrEqual(modelname, "models/weapons/melee/v_electric_guitar.mdl", false)) slotSecondary[client][slot] = "electric_guitar";
    else if (StrEqual(modelname, "models/weapons/melee/v_frying_pan.mdl", false)) slotSecondary[client][slot] = "frying_pan";
    else if (StrEqual(modelname, "models/weapons/melee/v_machete.mdl", false)) slotSecondary[client][slot] = "machete";
    else if (StrEqual(modelname, "models/weapons/melee/v_golfclub.mdl", false)) slotSecondary[client][slot] = "golfclub";
    else if (StrEqual(modelname, "models/weapons/melee/v_tonfa.mdl", false)) slotSecondary[client][slot] = "tonfa";
    else if (StrEqual(modelname, "models/weapons/melee/v_riotshield.mdl", false)) slotSecondary[client][slot] = "riotshield";
    else if (StrEqual(modelname, "models/v_models/v_dual_pistolA.mdl", false)) slotSecondary[client][slot] = "dualpistol";
    else GetEdictClassname(GetPlayerWeaponSlot(client, 1), slotSecondary[client][slot], MAX_LINE_WIDTH);
  }
  if (GetPlayerWeaponSlot(client, 2) == -1) slotThrowable[client][slot] = "";
  else GetEdictClassname(GetPlayerWeaponSlot(client, 2), slotThrowable[client][slot], MAX_LINE_WIDTH);
  if (GetPlayerWeaponSlot(client, 3) == -1) slotMedkit[client][slot] = "";
  else GetEdictClassname(GetPlayerWeaponSlot(client, 3), slotMedkit[client][slot], MAX_LINE_WIDTH);
  if (GetPlayerWeaponSlot(client, 4) == -1) slotPills[client][slot] = "";
  else GetEdictClassname(GetPlayerWeaponSlot(client, 4), slotPills[client][slot], MAX_LINE_WIDTH);
#if DBUG
  if (!afk)
  {
    LogToFile(LOG, "Вещи игрока %N, перед сменой карты после их сохранения:", client);
    LogToFile(LOG, "slotPrimary = [%s] | slotSecondary = [%s]", client, slotPrimary[client][0], slotSecondary[client][0]);
    LogToFile(LOG, "ammo[%d] | clip[%d] | upgrade[%d] | upgradeammo[%d]", priAmmo[client][0], priClip[client][0], priUpgrade[client][0], priUpgrAmmo[client][0]);
    LogToFile(LOG, "slotThrowable = [%s] | slotMedkit = [%s] | slotPills = [%s] | slotHealth = [%d]", slotThrowable[client][0], slotMedkit[client][0], slotPills[client][0], slotHealth[client]);
  }
#endif
  
  if ((g_cvar_clear_items.BoolValue && remove) || afk)
  {
    for (int i = 0; i < 5; i++)
    {
      if (GetPlayerWeaponSlot(client, i) > -1)
        RemovePlayerItem(client, GetPlayerWeaponSlot(client, i));
    }
    if (afk && TotalSurvivors() <= 4)
    {
      switch(GetRandomInt(0,1))
      {
        case 0: CheatCmd(client, "give", "pistol");
        case 1: CheatCmd(client, "give", "pistol_magnum");
      }
      switch(GetRandomInt(0,1))
      {
        case 0: CheatCmd(client, "give", "shotgun_chrome");
        case 1: CheatCmd(client, "give", "smg");
      }
    }
  }
}

public void RestoreClientData(int client, bool afk)
{
  if (!IsClientInGame(client) || GetClientTeam(client) != 2)
    return;
  
  for (int i = 0; i < 5; i++) if (GetPlayerWeaponSlot(client, i) > -1)
    RemovePlayerItem(client, GetPlayerWeaponSlot(client, i));
  
  if (g_cvar_check_steamid.BoolValue)
  {
    char steamId[MAX_STEAM_LENGTH];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    if (!StrEqual(slotAuth[client], steamId, false))
      ClearClientData(client);
  }
  if (IsFakeClient(client))
  {
    CheatCmd(client, "give", "pistol");
    CheatCmd(client, "give", "health");
    SetEntProp(client, Prop_Send, "m_iHealth", 100, 1);
    RemoveTempHealth(client);
    return;
  }
  int slot;
  if (afk) slot = 1;
  else slot = 0;
  if (!StrEqual(slotPrimary[client][slot], "", false))
  {
    CheatCmd(client, "give", slotPrimary[client][slot]);
    if (afk)
    {
      if (StrEqual(slotPrimary[client][slot], "weapon_rifle") || StrEqual(slotPrimary[client][slot], "weapon_rifle_sg552") || 
        StrEqual(slotPrimary[client][slot], "weapon_rifle_desert") || StrEqual(slotPrimary[client][slot], "weapon_rifle_ak47"))
        SetEntData(client, ammoOffset+(12), priAmmo[client][slot]);
      else if (StrEqual(slotPrimary[client][slot], "weapon_smg") || StrEqual(slotPrimary[client][slot], "weapon_smg_silenced") || 
        StrEqual(slotPrimary[client][slot], "weapon_smg_mp5"))
        SetEntData(client, ammoOffset+(20), priAmmo[client][slot]);
      else if (StrEqual(slotPrimary[client][slot], "weapon_pumpshotgun") || StrEqual(slotPrimary[client][slot], "weapon_shotgun_chrome"))
        SetEntData(client, ammoOffset+(28), priAmmo[client][slot]);
      else if (StrEqual(slotPrimary[client][slot], "weapon_autoshotgun") || StrEqual(slotPrimary[client][slot], "weapon_shotgun_spas"))
        SetEntData(client, ammoOffset+(32), priAmmo[client][slot]);
      else if (StrEqual(slotPrimary[client][slot], "weapon_hunting_rifle"))
        SetEntData(client, ammoOffset+(36), priAmmo[client][slot]);
      else if (StrEqual(slotPrimary[client][slot], "weapon_sniper_scout") || StrEqual(slotPrimary[client][slot], "weapon_sniper_military") || 
        StrEqual(slotPrimary[client][slot], "weapon_sniper_awp"))
        SetEntData(client, ammoOffset+(40), priAmmo[client][slot]);
      else if (StrEqual(slotPrimary[client][slot], "weapon_grenade_launcher"))
        SetEntData(client, ammoOffset+(68), priAmmo[client][slot]);
    }
    else
      SetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_bInReload", priAmmo[client][slot]);
    SetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_iClip1", priClip[client][slot]);
    SetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_upgradeBitVec", priUpgrade[client][slot]);
    SetEntProp(GetPlayerWeaponSlot(client, 0), Prop_Send, "m_nUpgradedPrimaryAmmoLoaded", priUpgrAmmo[client][slot]);
  }
  if (StrEqual(slotSecondary[client][slot], "", false)) CheatCmd(client, "give", "pistol");
  else if (StrEqual(slotSecondary[client][slot], "dualpistol", false))
  {
    CheatCmd(client, "give", "pistol");
    CheatCmd(client, "give", "pistol");
  }
  else CheatCmd(client, "give", slotSecondary[client][slot]);
  if (!StrEqual(slotThrowable[client][slot], "", false)) CheatCmd(client, "give", slotThrowable[client][slot]);
  if (!StrEqual(slotMedkit[client][slot], "", false)) CheatCmd(client, "give", slotMedkit[client][slot]);
  if (!StrEqual(slotPills[client][slot], "", false)) CheatCmd(client, "give", slotPills[client][slot]);
  if (afk)
  {
    if (g_iIncaps[client] == FindConVar("survivor_max_incapacitated_count").IntValue) BlackAndWhite(client);
    else SetEntProp(client, Prop_Send, "m_currentReviveCount", g_iIncaps[client]);
    SetEntityHealth(client, g_iPermHP[client]);
    SetTempHealth(client, g_iTempHP[client]);
    
    g_bGoToAFK[client] = false;
  }
  else
  {
    CheatCmd(client, "give", "health");
    if (slotHealth[client] < 51) SetEntProp(client, Prop_Send, "m_iHealth", 50, 1);
    else SetEntProp(client, Prop_Send, "m_iHealth", slotHealth[client], 1);
    RemoveTempHealth(client);
    
    g_bPlayerTake[client] = true;
  }
}

public int ClearClientData(int client)
{
  if (!IsClientInGame(client) || IsFakeClient(client)) return;
  
  slotPrimary[client][0] = "";
  slotPrimary[client][1] = "";
  if (g_cvar_give_items.BoolValue && GetClientTeam(client) == 2 && IsPlayerAlive(client) && (g_bFirstMap || g_iRounds > 2))
  {
    if (GetRandomInt(1, 5) > 2)
    {
      if (GetRandomInt(1, 2) == 1) slotSecondary[client][0] = "pistol";
      else slotSecondary[client][0] = "dualpistol";
    }
    else
    {
      if (GetRandomInt(1, 2) == 1) slotSecondary[client][0] = "pistol";
      else slotSecondary[client][0] = "pistol_magnum";
    }
  }
  else slotSecondary[client][0] = "pistol";
  slotSecondary[client][1] = "pistol";
  
  if (g_cvar_give_items.BoolValue && g_bFirstMap)
  {
    switch (GetRandomInt(1, 10))
    {
      case 1:
      {
        slotPrimary[client][0] = "pumpshotgun";
        priClip[client][0] = 40;
        slotMedkit[client][0] = "";
        slotThrowable[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 2:
      {
        slotPrimary[client][0] = "smg";
        priClip[client][0] = 50;
        slotMedkit[client][0] = "";
        slotThrowable[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 3: 
      {
        slotPrimary[client][0] = "pumpshotgun";
        priClip[client][0] = 40;
        slotMedkit[client][0] = "";
        slotThrowable[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 4:
      {
        slotPrimary[client][0] = "shotgun_chrome";
        priClip[client][0] = 8;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 5:
      {
        slotPrimary[client][0] = "smg";
        priClip[client][0] = 40;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 6:
      {
        slotPrimary[client][0] = "pumpshotgun";
        priClip[client][0] = 8;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 7:
      {
        slotPrimary[client][0] = "shotgun_chrome";
        priClip[client][0] = 40;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 8:
      {
        slotPrimary[client][0] = "smg";
        priClip[client][0] = 8;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 9:
      {
        slotPrimary[client][0] = "smg";
        priClip[client][0] = 50;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
      case 10:
      {
        slotPrimary[client][0] = "pumpshotgun";
        priClip[client][0] = 8;
        slotThrowable[client][0] = "";
        slotMedkit[client][0] = "";
        slotPills[client][0] = "";
        slotHealth[client] = 100;
      }
    }
    priAmmo[client][0] = 0;
    priUpgrade[client][0] = 0;
    priUpgrAmmo[client][0] = 0;
  }
  else if (g_cvar_give_items.BoolValue)
  {
    switch (GetRandomInt(1, 2))
    {
      case 1:
      {
        slotPrimary[client][0] = "pumpshotgun";
        priClip[client][0] = 8;
      }
      case 2: 
      {
        slotPrimary[client][0] = "smg";
        priClip[client][0] = 50;
      }
    }
    priAmmo[client][0] = 0;
    priUpgrade[client][0] = 0;
    priUpgrAmmo[client][0] = 0;
    
    slotMedkit[client][0] = "";
    slotPills[client][0] = "";
    slotHealth[client] = 50;
  }
  else
  {
    slotPrimary[client][0] = "";
    slotMedkit[client][0] = "";
    slotPills[client][0] = "";
    if (g_bFirstMap)
      slotHealth[client] = 100;
    else
      slotHealth[client] = 50;
  }
  
  slotThrowable[client][1] = "";
  slotMedkit[client][1] = "";
  slotPills[client][1] = "";
}

public int ClearClientDataFinal(int client)
{
  if (!IsClientInGame(client) || IsFakeClient(client)) return;
  int i = 0;
  while (i < 2)
  {
    slotPrimary[client][i] = "";
    slotSecondary[client][i] = "pistol";
    slotThrowable[client][i] = "";
    slotMedkit[client][i] = "";
    slotPills[client][i] = "";
    i += 1;
  }
  slotHealth[client] = 100;
}

public Action Timer_Bool(Handle timer, any client)
{
  int i = 1;
  while (i <= MaxClients)
  {
    if (IsValidEntity(i) && IsClientInGame(i) && !IsFakeClient(i))
    {
      g_bPlayerDeath[i] = false;
    }
    i += 1;
  }
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  
  if (client < 1) return Plugin_Handled;
  
  if (IsClientInGame(client) && GetClientTeam(client) == 2 && !IsFakeClient(client)) g_bPlayerDeath[client] = true;
  return Plugin_Handled;	
}

public void RemoveTempHealth(int client)
{
  if (!client || !IsValidEntity(client) || !IsClientInGame(client) || !IsPlayerAlive(client) || IsClientObserver(client) || GetClientTeam(client) != 2) return;
  SetTempHealth(client, 0.0);
}

public void SetTempHealth(int client, float hp)
{
  SetEntPropFloat(client, Prop_Send, "m_healthBufferTime", GetGameTime());
  SetEntPropFloat(client, Prop_Send, "m_healthBuffer", hp);
}

bool IsValidClient(int client)
{
  if (!IsValidEntity(client)) return false;
  if (client < 1 || client > MaxClients) return false;
  return true;
}

public void CheatCmd(int client, char[] sCommand, char[] sArgument)
{
  int iFlags = GetCommandFlags(sCommand);
  SetCommandFlags(sCommand, iFlags & ~FCVAR_CHEAT);
  FakeClientCommand(client, "%s %s", sCommand, sArgument);
  SetCommandFlags(sCommand, iFlags);
}

public Action Command_Load_Weapons(int client, int args)
{
  if (args == 0)
  {
    ReplyToCommand(client, "Using: keep_load_weapons <#userid|name>");
    return Plugin_Handled;
  }
  else if (args == 1)
  {
    char arg[65];
    GetCmdArg(1, arg, sizeof(arg));
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS];
    int target_count;
    bool tn_is_ml;
    int targetclient;
    if ((target_count = ProcessTargetString(arg, client, target_list, MAXPLAYERS, COMMAND_FILTER_ALIVE, target_name, sizeof(target_name), tn_is_ml)) <= 0)
    {
      ReplyToTargetError(client, target_count);
      return Plugin_Handled;
    }
    else
    {
      ReplyToCommand(client, "Weapons for player: %s was loaded", target_name);
      
      for (int i = 0; i < target_count; i++)
      {
        targetclient = target_list[i];
        RestoreClientData(targetclient, false);
      }
      return Plugin_Handled;
    }	
  }
  else
  {
    ReplyToCommand(client, "Using: keep_load_weapons <#userid|name>");
    return Plugin_Handled;
  }
}

public Action Command_Save_Weapons(int client, int args)
{
  if (args == 0)
  {
    ReplyToCommand(client, "Using: keep_save_weapons <#userid|name>");
    return Plugin_Handled;
  }
  else if (args == 1)
  {
    char arg[65];
    GetCmdArg(1, arg, sizeof(arg));
    char target_name[MAX_TARGET_LENGTH];
    int target_list[MAXPLAYERS];
    int target_count;
    bool tn_is_ml;
    int targetclient;
    if ((target_count = ProcessTargetString(arg, client, target_list, MAXPLAYERS, COMMAND_FILTER_ALIVE, target_name, sizeof(target_name), tn_is_ml)) <= 0)
    {
      ReplyToTargetError(client, target_count);
      return Plugin_Handled;
    }
    else
    {
      ReplyToCommand(client, "Weapons for player: %s was saved", target_name);
      
      for (int i = 0; i < target_count; i++)
      {
        targetclient = target_list[i];
        SaveClientData(targetclient, false, false);
      }
      return Plugin_Handled;
    }	
  }
  else
  {
    ReplyToCommand(client, "Using: keep_save_weapons <#userid|name>");
    return Plugin_Handled;
  }
}

/*===========================// AFK part //===========================*/
public Action Cmd_AFK(int client, int args)
{
  Command_AFK(client, 0);
  return Plugin_Handled;
}

public Action Command_AFK(int client, int args)
{
  if (!client) return Plugin_Handled;
  
  if (IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 2)
  {
    if (!g_bWaitAFK[client])
    {
      if (CheckCommandAccess(client, "sm_fake_command", ADMFLAG_KICK, true) && !IsPlayerBussy(client))
      {
        CreateTimer(0.1, MoveToSpec1, client);
        g_bWaitAFK[client] = true;
        return Plugin_Handled;
      }
      else
      {
        if (IsTankAlive())
        {
          PrintHintText(client, "%t", "You can't join spectator team with a good weapon and a live tank");
          return Plugin_Handled;
        }
        else
        {
          float fAFK = GetRandomFloat(10.0, 20.0);
          CreateTimer(fAFK, MoveToSpec1, client);
          PrintHintText(client, "%t", "Going to AFK after %.0f seconds", fAFK);
          g_bWaitAFK[client] = true;
          return Plugin_Handled;
        }
      }
    }
  }
  return Plugin_Handled;
}

public Action MoveToSpec1(Handle timer, any client)
{
  if (IsClientInGame(client))
  {
    if (!IsFakeClient(client) && GetClientTeam(client) == 2 && !IsPlayerBussy(client) && !g_bMapTranslition)
    {
      SaveClientData(client, false, true);
      FakeClientCommand(client, "sm_louis");
      CleanAura(client);
      CreateTimer(0.1, MoveToSpec2, client);
    }
    g_bWaitAFK[client] = false;
  }
  return Plugin_Stop;
}

public void CleanAura(int client)
{
  if (client < 1) return;
  if (!IsValidEntity(client)) return;
  if (!IsClientInGame(client)) return;
  if (GetClientTeam(client) != 2) return;

  SetEntProp(client, Prop_Send, "m_iGlowType", 0);
  SetEntProp(client, Prop_Send, "m_glowColorOverride", 0);
}

public Action MoveToSpec2(Handle timer, any client)
{
  if (IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client) && !g_bMapTranslition)
  {
    ChangeClientTeam(client, 1);
    PrintToChatAll("%t", "[AFK] Player %N was moved to Spectator team.", client);
    g_bGoToAFK[client] = true;
  }
  return Plugin_Stop;
}

public Action Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
  if (event.GetBool("disconnect"))
    return;
  
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (!client || IsFakeClient(client) || event.GetInt("team") == 1)
    return;
  
  if (g_bGoToAFK[client])
    CreateTimer(1.7, ClientChangeTeam, client);
  else
  {
    if (!g_bPlayerDeath[client])
      CreateTimer(1.7, ClientChangeTeam, client);
  }
  SetEngineTime(client);
}

public Action ClientChangeTeam(Handle timer, any client)
{
  if (client > 0 && IsClientInGame(client) && !IsFakeClient(client) && GetClientTeam(client) == 2 && IsPlayerAlive(client))
  {
    if (g_bGoToAFK[client])
      RestoreClientData(client, true);
    else
    {
      if (!g_bPlayerTake[client])
        RestoreClientData(client, false);
    }
  }
}

float GetSurvivorTempHealth(int client)
{
  float fHealth = GetEntPropFloat(client, Prop_Send, "m_healthBuffer");
  fHealth -= (GetGameTime() - GetEntPropFloat(client, Prop_Send, "m_healthBufferTime")) * FindConVar("pain_pills_decay_rate").FloatValue;
  return fHealth < 0.0 ? 0.0 : fHealth;
}

public int BlackAndWhite(int client)
{
  if (client > 0 && IsValidEntity(client) && IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == 2)
  {
    SetEntProp(client, Prop_Send, "m_currentReviveCount", FindConVar("survivor_max_incapacitated_count").IntValue - 1);
    SetEntProp(client, Prop_Send, "m_isIncapacitated", 1);
    SDKCall(hRoundRevive, client);
    SetEntityHealth(client, 1);
    SetTempHealth(client, 45.0);
  }
}

public Action Event_SurvivorRescued(Event event, const char[] name, bool dontBroadcast)
{
  int target = GetClientOfUserId(event.GetInt("victim")); 
  if (!target) return;

  if (!IsFakeClient(target)) g_fButtonTime[target] = (GetEngineTime() - (g_iCvarSpecT * 0.5));
}

public int SetEngineTime(int client)
{
  g_fButtonTime[client] = GetEngineTime();
}

public Action Event_PlayerSay(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  if (!client) return;

  if (GetClientTeam(client) != 1) SetEngineTime(client);
}

public Action OnPlayerRunCmd(int client, int &buttons)
{
  if (buttons && !g_bTempBlock[client] && !IsFakeClient(client))
  {
    switch (GetClientTeam(client))
    {
      case 2:
        if (IsPlayerAlive(client)) SAM_PluseTime(client);
      case 3:
        SAM_PluseTime(client);
    }
  }
}

public int SAM_PluseTime(int client)
{
  SetEngineTime(client);
  g_bTempBlock[client] = true;
  CreateTimer(CHECK_TIME, SAM_t_Unlock, client);
}

public Action SAM_t_Unlock(Handle timer, any client)
{
  g_bTempBlock[client] = false;
}

public void convar_AfkSpecTime(ConVar convar, const char[] oldValue, const char[] newValue) 
{
  g_iCvarSpecT = StringToFloat(newValue);
  if (g_iCvarSpecT == 0.0 || g_iCvarSpecT <= 40.0) 
  {
    convar.SetFloat(40.0);
    return;
  }
}

public Action SAM_t_CheckIdles(Handle timer)
{
  if (!IsServerProcessing()) return Plugin_Continue;
  if (g_bMapTranslition) return Plugin_Continue;
  
  static float fTheTime;
  fTheTime = GetEngineTime();

  int i = 1;
  while (i <= MaxClients)
  {
    if (g_fButtonTime[i] && (fTheTime - g_fButtonTime[i]) > g_iCvarSpecT)
    {
      if (IsClientInGame(i) && GetClientTeam(i) == 2)
      {
        if (IsPlayerBussy(i) || GetLiveSurvivorsCount() < 2)
        {
          g_fButtonTime[i] = fTheTime;
          continue;
        }

        SaveClientData(i, false, true);
        CleanAura(i);
        float fAFK = GetRandomFloat(0.1, 0.9);
        CreateTimer(fAFK, MoveToSpec2, i);
      }
      else
        g_fButtonTime[i] = fTheTime;
    }
    i += 1;
  }
  
  return Plugin_Continue;
}

bool IsTankAlive()
{
  int i = 1;
  while (i <= MaxClients)
  {
    if (IsClientInGame(i) && GetClientTeam(i) == 3 && IsPlayerAlive(i))
    {
      char iClass[100];
      GetClientModel(i, iClass, sizeof(iClass));
      
      if (StrContains(iClass, "hulk", true) > -1)
      {
        return true;
      }
    }
    i += 1;
  }
  return false;
}

bool IsPlayerBussy(int client)
{
  if (!IsPlayerAlive(client)) return true;
  if (IsPlayerIncapped(client)) return true;
  if (IsPlayerGrapEdge(client)) return true;
  if (IsSurvivorBussy(client)) return true;
  return false;
}

bool IsPlayerGrapEdge(int client)
{
  if (GetEntProp(client, Prop_Send, "m_isHangingFromLedge", 1)) return true;
  if (GetEntProp(client, Prop_Send, "m_isFallingFromLedge", 1)) return true;
  return false;
}

bool IsSurvivorBussy(int client)
{
  return GetEntProp(client, Prop_Send, "m_tongueOwner") > 0 || GetEntProp(client, Prop_Send, "m_pounceAttacker") > 0 || (GetEntProp(client, Prop_Send, "m_pummelAttacker") > 0 || GetEntProp(client, Prop_Send, "m_jockeyAttacker") > 0);
}

bool IsPlayerIncapped(int client)
{
  if (GetEntProp(client, Prop_Send, "m_isIncapacitated", 1)) return true;
  return false;
}

int GetLiveSurvivorsCount()
{
  int clients = 0;

  int i = 1;
  while (i <= MaxClients)
  {
    if (IsClientInGame(i) && GetClientTeam(i) == 2 && !IsFakeClient(i) && !IsPlayerBussy(i))
    {
      clients++;
    }
    i += 1;
  }
  return clients;
}

int TotalSurvivors()
{
  int sur = 0;
  for (int i = 1; i <= MaxClients; i++)
  {
    if (IsClientConnected(i))
    {
      if (IsClientInGame(i) && (GetClientTeam(i) == 2))
        sur++;
    }
  }
  return sur;
}