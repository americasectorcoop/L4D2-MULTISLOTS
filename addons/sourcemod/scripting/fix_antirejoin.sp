#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <colors>

#define DB_CONF_NAME "storage-local"
#define PLUGIN_VERSION "1.0.2"

public Plugin myinfo = 
{
  name = "Anti-Rejoin",
  author = "exvel",
  description = "Slays players who are killed during a round then leave and rejoin the server in the same round then spawn to play the same round more than once",
  version = PLUGIN_VERSION,
  url = "www.sourcemod.net"
}

bool played[MAXPLAYERS + 1];
bool reconnected[MAXPLAYERS + 1];
Database db = null;

public OnPluginStart()
{
  InitDB();
  HookEvent("player_spawn", Event_PlayerSpawn, EventHookMode_Post);
  HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
  HookEvent("round_start", Event_RoundStart, EventHookMode_Pre);
  HookEvent("player_death", Event_PlayerDeath, EventHookMode_Post);
  LoadTranslations("antirejoin.phrases.txt");
}

public Action Event_PlayerDeath(Event event, const char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  if(client)
  {
    if(!IsFakeClient(client))
    {
      if(GetClientTeam(client))
      {
        played[client] = true;
      }
    }
  }	
}

public Action Event_PlayerSpawn(Event event, char[] name, bool dontBroadcast)
{
  int client = GetClientOfUserId(event.GetInt("userid"));
  
  if(client)
  {
    if(!IsFakeClient(client))
    {
      if(GetClientTeam(client))
      {
        if(played[client] && reconnected[client])
        {
          int frags = GetClientFrags(client);
          int deaths = GetClientDeaths(client);
          
          ForcePlayerSuicide(client);
          CPrintToChat(client, "\x05[\x04Antireconnect\x05]\x05 %t", "You slayed");
          
          SetFrags(client, frags);
          SetDeaths(client, deaths);
          
          reconnected[client] = false;
          
          return;
        }
        
        char steamId[20], query[200];
        GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
        Format(query, sizeof(query), "DELETE FROM antirejoin WHERE steamid = '%s';", steamId);
        SQL_FastQuery(db, query);
      }
    }
  }	
}

public void ClearInfo()
{
  for (int i = 0; i < MaxClients; i++)
  {
    played[i] = false;
    reconnected[i] = false;
  }
  ClearDB();
}

public Action Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
  ClearInfo();
  ClearDB();
  return Plugin_Continue;
}

public Action Event_RoundStart(Event event, const char[] name, bool dontBroadcast)
{
  ClearInfo();
  ClearDB();
  return Plugin_Continue;
}

public void OnMapStart()
{
  ClearInfo();
  ClearDB();
}

public void OnClientPutInServer(int client)
{
  if (IsFakeClient(client))
  {
    return;
  }
  
  char steamId[20], query[200];	
  GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
  Format(query, sizeof(query), "SELECT * FROM	antirejoin WHERE steamid = '%s';", steamId);
  db.Query(CheckPlayer, query, client);
}

public void CheckPlayer(Database db, DBResultSet results, const char[] error, int client)
{
  if (!db || !results || error[0]) {
    LogError("[antirejoin(CheckPlayer)] Failed to query (error: %s)", error);
  } else if (results.RowCount == 0) {
      played[client] = false;
      reconnected[client] = false;
  } else {
    played[client] = true;
    reconnected[client] = true;
  }
}

public void OnClientDisconnect(int client)
{
  if ( played[client] )
  {
    char steamId[20], query[200];
    GetClientAuthId(client, AuthId_Steam2, steamId, sizeof(steamId));
    SQL_LockDatabase(db);		
    Format(query, sizeof(query), "INSERT OR IGNORE INTO antirejoin VALUES ('%s');", steamId);
    SQL_FastQuery(db, query);
    SQL_UnlockDatabase(db);
  }
}

public void InitDB()
{
  if (SQL_CheckConfig(DB_CONF_NAME))
  {
    char Error[80];
    db = SQL_Connect(DB_CONF_NAME, true, Error, sizeof(Error));

    if (db != null)
    {
      SQL_LockDatabase(db);
      if(!SQL_FastQuery(db, "CREATE TABLE IF NOT EXISTS antirejoin (steamid TEXT);"))
      {
        SQL_GetError(db, Error, sizeof(Error));
        LogError("SQL Error: %s", Error);
        SetFailState("SQL Error: %s", Error);
      }
      SQL_UnlockDatabase(db);
    }
    else
    {
      LogError("Failed to connect to database: %s", Error);
      SetFailState("Failed to connect to database: %s", Error);
    }
  }
  else
  {
    LogError("database.cfg missing '%s' entry!", DB_CONF_NAME);
    SetFailState("database.cfg missing '%s' entry!", DB_CONF_NAME);
  }
}


public void ClearDB()
{
  SQL_LockDatabase(db);
  SQL_FastQuery(db, "DELETE FROM antirejoin;");
  SQL_UnlockDatabase(db);
}

public void SetFrags(int client, any frags)
{
  SetEntProp(client, Prop_Data, "m_iFrags", frags);
}

public void SetDeaths(int client, any deaths)
{
  SetEntProp(client, Prop_Data, "m_iDeaths", deaths);
}

public void SendSQLUpdate(char[] query)
{
  if (db != null)
  {
    db.Query(SQLErrorCheckCallback, query);
  }	
}

public void SQLErrorCheckCallback(Handle owner, Handle hndl, const char[] error, any data)
{
  if (db != null)
  {
    if(!StrEqual("", error))
    {
      LogError("SQL Error: %s", error);
    }
  }
}