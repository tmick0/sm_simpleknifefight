#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <autoexecconfig>
#include <nativevotes>

#pragma newdecls required

public Plugin myinfo =
{
    name = "simpleknifefight",
    author = "tmick0",
    description = "Allows players to choose to knife fight in a 1v1",
    version = "0.3",
    url = "github.com/tmick0/sm_simpleknifefight"
};

#define CVAR_ENABLE "sm_simpleknifefight_enable"
#define CVAR_DEBUG "sm_simpleknifefight_debug"
#define CVAR_MINHEALTH "sm_simpleknifefight_minhealth"
#define CVAR_MINTIME "sm_simpleknifefight_mintime"
#define CVAR_WAITTIME "sm_simpleknifefight_waittime"
#define CVAR_FREEZE "sm_simpleknifefight_freeze"
#define CVAR_TELEPORT "sm_simpleknifefight_teleport"
#define CVAR_MINSPAWNDISTANCE "sm_simpleknifefight_minspawndistance"

#define CMD_KNIFEFIGHT "knifefight"
#define CMD_KNIFEFIGHT_SHORT "kf"

#define ENTITY_NAME_MAX 128
#define MAX_MIN_SPAWN_DISTANCE 128.0

#define KNIFE_GENERIC "weapon_knife"
#define KNIFE_BAYONET "weapon_bayonet"
#define KNIFE_MELEE "weapon_melee"
#define KNIFE_GENERIC_LEN 12

int Enabled;
int Debug;
int MinTime;
int MinHealth;
int RoundStartTime;
int WaitTime;
int Freeze;
int Teleport;
float MinSpawnDistance;

int State;
int Voted[2];
int Entity[2];
Handle WaitTimer = INVALID_HANDLE;
NativeVote VoteHandle;
bool VoteValid = false;

#define INDEX_T 0
#define INDEX_CT 1
#define INDEX_COUNT 2

#define TELEPORT_OFF 0
#define TELEPORT_T 1
#define TELEPORT_CT 2

#define STATE_NOT_1v1 0
#define STATE_1v1 1
#define STATE_WAIT 2
#define STATE_KNIFE 3

ConVar CvarEnable;
ConVar CvarDebug;
ConVar CvarMinTime;
ConVar CvarMinHealth;
ConVar CvarWaitTime;
ConVar CvarFreeze;
ConVar CvarTeleport;
ConVar CvarMinSpawnDistance;

#define FOR_EACH_INDEX(%1) for (int %1 = 0; %1 < INDEX_COUNT; ++%1)

public void OnPluginStart() {
    // init config    
    AutoExecConfig_SetCreateDirectory(true);
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetFile("plugin_simpleknifefight");
    CvarDebug = AutoExecConfig_CreateConVar(CVAR_DEBUG, "0", "1 = enable debug output, 0 = disable");
    CvarEnable = AutoExecConfig_CreateConVar(CVAR_ENABLE, "0", "1 = enable !knifefight in 1v1, 0 = disable");
    CvarMinTime = AutoExecConfig_CreateConVar(CVAR_MINTIME, "0", "minimum remaining round time in seconds for knife fight (time will be added to reach this value)");
    CvarMinHealth = AutoExecConfig_CreateConVar(CVAR_MINHEALTH, "0", "minimum remaining player health for knife fight (health will be added to reach this value)");
    CvarWaitTime = AutoExecConfig_CreateConVar(CVAR_WAITTIME, "0", "seconds to wait after both players accept before starting the knife fight");
    CvarFreeze = AutoExecConfig_CreateConVar(CVAR_FREEZE, "0", "if 1, players will be frozen during the wait time");
    CvarTeleport = AutoExecConfig_CreateConVar(CVAR_TELEPORT, "0", "if 't' or 'ct' the players engaging in a knife fight will be teleported to that spawn; if 0 do not teleport");
    CvarMinSpawnDistance = AutoExecConfig_CreateConVar(CVAR_MINSPAWNDISTANCE, "64", "minimum distance between players when teleporting");
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // init hooks
    HookConVarChange(CvarDebug, CvarsUpdated);
    HookConVarChange(CvarEnable, CvarsUpdated);
    HookConVarChange(CvarMinTime, CvarsUpdated);
    HookConVarChange(CvarMinHealth, CvarsUpdated);
    HookConVarChange(CvarWaitTime, CvarsUpdated);
    HookConVarChange(CvarFreeze, CvarsUpdated);
    HookConVarChange(CvarTeleport, CvarsUpdated);
    HookConVarChange(CvarMinSpawnDistance, CvarsUpdated);
    RegConsoleCmd(CMD_KNIFEFIGHT, KnifeFightCmd, "vote to knife fight in a 1v1");
    RegConsoleCmd(CMD_KNIFEFIGHT_SHORT, KnifeFightCmd, "vote to knife fight in a 1v1");
    HookEvent("player_death", OnPlayerDeath, EventHookMode_PostNoCopy);
    HookEvent("round_end", OnRoundEnd, EventHookMode_PostNoCopy);
    HookEvent("round_start", OnRoundStart, EventHookMode_PostNoCopy);

    // load config
    SetCvars();

    // initialize plugin state
    RoundStartTime = 0;
    ReinitState(true);
}

void ReinitState(bool check) {
    if (State > STATE_1v1) {
        EndKnifeFight();
    }

    State = STATE_NOT_1v1;
    FOR_EACH_INDEX(i) {
        Voted[i] = 0;
    }

    if (check && Enabled) {
        Check1v1();
    }

    EndVote(false);
}

void CvarsUpdated(ConVar cvar, const char[] oldval, const char[] newval) {
    SetCvars();
}

void SetCvars() {
    int prevEnabled = Enabled;

    Debug = CvarDebug.IntValue;
    Enabled = CvarEnable.IntValue;
    MinTime = CvarMinTime.IntValue;
    MinHealth = CvarMinHealth.IntValue;
    Freeze = CvarFreeze.IntValue;
    WaitTime = CvarWaitTime.IntValue;
    MinSpawnDistance = CvarMinSpawnDistance.FloatValue;
    if (MinSpawnDistance > MAX_MIN_SPAWN_DISTANCE) {
        MinSpawnDistance = MAX_MIN_SPAWN_DISTANCE;
        LogMessage("%s was capped at %f", CVAR_MINSPAWNDISTANCE, MAX_MIN_SPAWN_DISTANCE);
    }

    char tp[8];
    CvarTeleport.GetString(tp, sizeof(tp));
    if (StrEqual(tp, "t", false)) {
        Teleport = TELEPORT_T;
    } else if (StrEqual(tp, "ct", false)) {
        Teleport = TELEPORT_CT;
    }
    else {
        Teleport = TELEPORT_OFF;
    }

    if (Enabled && !prevEnabled) {
        ReinitState(true);
    }
}

void ShowVote(int client, int enemy) {
    int tmp[1];
    tmp[0] = client;

    VoteHandle = new NativeVote(VoteResponseHandler, NativeVotesType_Custom_YesNo);
    VoteHandle.Initiator = enemy;
    VoteHandle.SetTitle("Knife?");
    VoteHandle.SetDetails("It's 1v1. Agree to a knife fight?");
    VoteHandle.DisplayVote(tmp, 1, 15, 0);
    VoteValid = true;
}

void EndVote(bool success, bool via_command=false) {
    if (VoteValid) {
        FOR_EACH_INDEX(i) {
            if (!Voted[i]) {
                if (success) {
                    VoteHandle.DisplayPassCustomToOne(Entity[i], "Knife fight accepted.");
                    if (!via_command) {
                        KnifeFightCmd(Entity[i], 0);
                    }
                } else {
                    VoteHandle.DisplayFail();
                }
            }
        }
        VoteHandle.Close();
        VoteValid = false;
    }
}

public int VoteResponseHandler(NativeVote vote, MenuAction action, int param1, int param2) {
	switch (action) {
		case MenuAction_End: {
			vote.Close();
		}
		
		case MenuAction_VoteCancel: {
			if (param1 == VoteCancel_NoVotes) {
				EndVote(false);
			} else {
				EndVote(false);
			}
		}
		
		case MenuAction_VoteEnd: {
			if (param1 == NATIVEVOTES_VOTE_NO) {
				EndVote(false);
			} else {
				EndVote(true);
			}
		}
	}
}

Action KnifeFightCmd(int client, int argc) {
    if (!Enabled) {
        return Plugin_Continue;
    }

    if (Debug) {
        LogMessage("got KnifeFightCmd: state=%d voted[T]=%d voted[CT]=%d", State, Voted[INDEX_T], Voted[INDEX_CT]);
    }

    if (State != STATE_1v1) {
        ReplyToCommand(client, "The %s command is only valid during a 1v1 situation", CMD_KNIFEFIGHT);
        return Plugin_Handled;
    }

    int slot;
    int other_slot;
    if (client == Entity[INDEX_T]) {
        slot = INDEX_T;
        other_slot = INDEX_CT;
    }
    else if (client == Entity[INDEX_CT]) {
        slot = INDEX_CT;
        other_slot = INDEX_T;
    }
    else {
        ReplyToCommand(client, "The %s command is for the players who are alive", CMD_KNIFEFIGHT);
        return Plugin_Handled;
    }

    if (Voted[slot]) {
        ReplyToCommand(client, "You already voted");
        return Plugin_Handled;
    }

    Voted[slot] = 1;

    char name[128];
    GetClientName(client, name, sizeof(name));
    
    if (!Voted[other_slot]) {
        PrintToChatAll("%s wants to knife fight!", name);
        PrintHintText(Entity[other_slot], "%s has challenged you to a knife fight!", name, CMD_KNIFEFIGHT_SHORT);
        ShowVote(Entity[other_slot], Entity[slot]);
    }
    else {
        PrintToChatAll("%s has agreed to a knife fight!", name);
        EndVote(true, true);
        KnifeFightAgreed();
    }

    return Plugin_Handled;
}

void KnifeFightAgreed() {
    // ensure each player has the minimum health and has a knife, and add the damage hook to them
    FOR_EACH_INDEX(i) {
        int health = GetClientHealth(Entity[i]);
        if (health < MinHealth) {
            if (Debug) {
                LogMessage("health of player %d was %d, setting it to %d", Entity[i], health, MinTime);
            }
            SetEntityHealth(Entity[i], MinHealth);
        }
        int weapon = GetPlayerWeaponSlot(Entity[i], CS_SLOT_KNIFE);
        if (weapon == -1) {
            weapon = GivePlayerItem(Entity[i], KNIFE_GENERIC);
        }
        SetEntPropEnt(Entity[i], Prop_Send, "m_hActiveWeapon", weapon);
        SDKHook(Entity[i], SDKHook_OnTakeDamage, OnTakeDamage);
    }

    // add time if necessary
    int roundTimeLimit = GameRules_GetProp("m_iRoundTime", 4, 0);
    int timeRemaining = RoundStartTime + roundTimeLimit - GetTime();
    if (Debug) {
        LogMessage("round time limit %d", roundTimeLimit);
        LogMessage("round start time %d", RoundStartTime);
        LogMessage("current time %d", GetTime());
        LogMessage("remaining round time was %d", timeRemaining);
    }
    if (timeRemaining < MinTime + WaitTime) {
        if (RoundStartTime > 0) {
            roundTimeLimit = roundTimeLimit + MinTime + WaitTime - timeRemaining;
            if (Debug) {
                LogMessage("setting round time to %d", roundTimeLimit);
            }
            GameRules_SetProp("m_iRoundTime", roundTimeLimit, 4, 0, true);
        }
        else {
            LogMessage("RoundStartTime was not set, not extending the round");
        }
    }

    // move the players, if enabled
    TeleportPlayers();

    // start or schedule the fight
    if (WaitTime) {
        StartWaitTimer();
    }
    else {
        StartKnifeFight();
    }
}

void StartWaitTimer() {
    State = STATE_WAIT;
    #define msg "The knife fight will begin in %d seconds."
    PrintToChatAll(msg, WaitTime);
    FOR_EACH_INDEX(i) {
        if (Freeze) {
            SetEntityMoveType(Entity[i], MOVETYPE_NONE);
        }
        PrintHintText(Entity[i], msg, WaitTime);
    }
    #undef msg
    WaitTimer = CreateTimer(1.0 * WaitTime, WaitTimerDone, 0, TIMER_FLAG_NO_MAPCHANGE);
}

Action WaitTimerDone(Handle timer) {
    KillTimer(WaitTimer);
    WaitTimer = INVALID_HANDLE;
    if (State == STATE_WAIT) {
        FOR_EACH_INDEX(i) {
            SetEntityMoveType(Entity[i], MOVETYPE_WALK);
        }
        StartKnifeFight();
    }
}

void StartKnifeFight() {
    State = STATE_KNIFE;
    #define msg "Let the knife fight begin!"
    PrintToChatAll(msg);
    FOR_EACH_INDEX(i) {
        PrintHintText(Entity[i], msg);
    }
    #undef msg
}

void EndKnifeFight() {
    FOR_EACH_INDEX(i) {
        SDKUnhook(Entity[i], SDKHook_OnTakeDamage, OnTakeDamage);
    }
    if (WaitTimer != INVALID_HANDLE) {
        KillTimer(WaitTimer);
        WaitTimer = INVALID_HANDLE;
    }
}

void Check1v1() {
    if (!Enabled || State != STATE_NOT_1v1) {
        return;
    }

    FOR_EACH_INDEX(i) {
        Entity[i] = -1;
    }

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i) && IsClientInGame(i) && IsPlayerAlive(i)) {
            int team = GetClientTeam(i);
            if (team == CS_TEAM_T) {
                team = INDEX_T;
            }
            else if (team == CS_TEAM_CT) {
                team = INDEX_CT;
            }
            else {
                continue;
            }

            if (Entity[team] != -1) {
                return;
            }

            Entity[team] = i;
        }
    }

    if (Entity[INDEX_T] != -1 && Entity[INDEX_CT] != -1) {
        State = STATE_1v1;
        #define msg "It's 1v1! Type !%s to knife fight!"
        FOR_EACH_INDEX(i) {
            PrintHintText(Entity[i], msg, CMD_KNIFEFIGHT);
            PrintToChat(Entity[i], msg, CMD_KNIFEFIGHT);
        }
        #undef msg
    }
}

void TeleportPlayers() {
    char classname[32];
    if (Teleport == TELEPORT_T) {
        strcopy(classname, sizeof(classname), "info_player_terrorist");
    } else if (Teleport == TELEPORT_CT) {
        strcopy(classname, sizeof(classname), "info_player_counterterrorist");
    } else {
        return;
    }

    int count = 0;
    int ent = 1;
    char entname[128];
    int spawns[32];

    // collect all spawns
    while ((ent = FindEntityByClassname(ent, classname)) != -1 && count < 32) {
        GetEntPropString(ent, Prop_Data, "m_iName", entname, sizeof(entname));
        // skip wingman spawns
        if (StrEqual(classname, "spawnpoints.2v2")) {
            continue;
        }
        spawns[count++] = ent;
    }

    // randomly select two spawns
    int tries = 0;
    int selected[2];
    selected[0] = GetRandomInt(0, count - 1);
    selected[1] = GetRandomInt(0, count - 1);
    while (SpawnDistance(selected[0], selected[1]) < MinSpawnDistance && tries++ < 10) {
        selected[1] = GetRandomInt(0, count - 1);
    }
    if (tries >= 10) {
        LogMessage("warning: took too many attempts to find distant enough spawns, try reducing %s", CVAR_MINSPAWNDISTANCE);
    }

    // teleport the players
    FOR_EACH_INDEX(i) {
        float vec[3];
        float ang[3];
        float vel[3] = {0.0, 0.0, 0.0};
        GetEntPropVector(spawns[i], Prop_Data, "m_vecOrigin", vec);
        GetEntPropVector(spawns[i], Prop_Data, "m_angRotation", ang);
        TeleportEntity(Entity[i], vec, ang, vel);
    }

}

float SpawnDistance(int e1, int e2) {
    float vec1[3];
    float vec2[3];
    GetEntPropVector(e1, Prop_Data, "m_vecOrigin", vec1);
    GetEntPropVector(e2, Prop_Data, "m_vecOrigin", vec2);
    return GetVectorDistance(vec1, vec2, false);
}

public Action OnTakeDamage(int victim, int& attacker, int &inflictor, float& damage, int& damagetype, int& weapon, float damageForce[3], float damagePosition[3])
{
    if (!Enabled || State <= STATE_1v1) {
        return Plugin_Continue;
    }

    if (State == STATE_WAIT) {
        damage = 0.0;
        if (Debug) {
            LogMessage("blocking %f damage due to wait time", damage);
        }
        return Plugin_Changed;
    }

    if (weapon < 0) {
        damage = 0.0;
        if (Debug) {
            LogMessage("negative weapon entity id %d, blocking %f damage", weapon, damage);
        }
        return Plugin_Changed;
    }

    char entity[ENTITY_NAME_MAX];
    GetEdictClassname(weapon, entity, ENTITY_NAME_MAX);

    bool allow = false;
    if (StrEqual(KNIFE_BAYONET, entity) || StrEqual(KNIFE_MELEE, entity)) {
        allow = true;
    }
    else {
        entity[KNIFE_GENERIC_LEN] = '\0';
        if (StrEqual(KNIFE_GENERIC, entity)) {
            allow = true;
        }
    }

    if (allow) {
        if (Debug) {
            LogMessage("allowing %f damage from \"%s\" (%d)", damage, entity, weapon);
        }
        return Plugin_Continue;
    }

    if (Debug) {
        LogMessage("blocking %f damage from \"%s\" (%d)", damage, entity, weapon);
    }

    damage = 0.0;
    return Plugin_Changed;
}

public Action OnPlayerDeath(Event event, const char[] eventName, bool dontBroadcast) {
    if (!Enabled) {
        return Plugin_Continue;
    }
    if (Debug) {
        LogMessage("got EventPlayerDeath: state=%d", State);
    }
    if (State == STATE_KNIFE) {
        int winner;
        if (IsPlayerAlive(Entity[INDEX_T])) {
            winner = Entity[INDEX_T];
        }
        else if (IsPlayerAlive(Entity[INDEX_CT])) {
            winner = Entity[INDEX_CT];
        }
        else {
            PrintToChatAll("Nobody won the knife fight. (???)");
            ReinitState(false);
            return Plugin_Continue;
        }

        char name[128];
        GetClientName(winner, name, sizeof(name));
        PrintToChatAll("%s won the knife fight!", name);
        ReinitState(false);
        return Plugin_Continue;
    }
    else if (State >= STATE_1v1) {
        ReinitState(false);
        return Plugin_Continue;
    }
    else {
        Check1v1();
        return Plugin_Continue;
    }
}

public Action OnRoundEnd(Event event, const char[] eventName, bool dontBroadcast) {
    if (!Enabled) {
        return Plugin_Continue;
    }
    if (State == STATE_KNIFE) {
        PrintToChatAll("Nobody won the knife fight.");
    }
    ReinitState(false);
    return Plugin_Handled;
}

public Action OnRoundStart(Event event, const char[] eventName, bool dontBroadcast) {
    RoundStartTime = GetTime() + FindConVar("mp_freezetime").IntValue;
}
