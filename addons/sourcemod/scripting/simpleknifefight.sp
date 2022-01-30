#include <sourcemod>
#include <sdkhooks>
#include <sdktools>
#include <cstrike>
#include <autoexecconfig>

#pragma newdecls required

public Plugin myinfo =
{
    name = "simpleknifefight",
    author = "tmick0",
    description = "Allows players to choose to knife fight in a 1v1",
    version = "0.2",
    url = "github.com/tmick0/sm_simpleknifefight"
};

#define CVAR_ENABLE "sm_simpleknifefight_enable"
#define CVAR_DEBUG "sm_simpleknifefight_debug"
#define CVAR_MINHEALTH "sm_simpleknifefight_minhealth"
#define CVAR_MINTIME "sm_simpleknifefight_mintime"

#define CMD_KNIFEFIGHT "knifefight"
#define CMD_KNIFEFIGHT_SHORT "kf"

#define ENTITY_NAME_MAX 128

#define KNIFE_GENERIC "weapon_knife"
#define KNIFE_BAYONET "weapon_bayonet"
#define KNIFE_MELEE "weapon_melee"
#define KNIFE_GENERIC_LEN 12

int Enabled;
int Debug;
int MinTime;
int MinHealth;
int State;
int RoundStartTime = 0;
int Voted[2];
int Entity[2];

#define INDEX_T 0
#define INDEX_CT 1
#define INDEX_COUNT 2

#define STATE_NOT_1v1 0
#define STATE_1v1 1
#define STATE_KNIFE 2

ConVar CvarEnable;
ConVar CvarDebug;
ConVar CvarMinTime;
ConVar CvarMinHealth;

#define FOR_EACH_INDEX(%1) for (int %1 = 0; %1 < INDEX_COUNT; ++%1)

public void OnPluginStart() {
    // init config    
    AutoExecConfig_SetCreateDirectory(true);
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetFile("plugin_simpleknifefight");
    CvarDebug = AutoExecConfig_CreateConVar(CVAR_DEBUG, "0", "1 = enable debug output, 0 = disable");
    CvarEnable = AutoExecConfig_CreateConVar(CVAR_ENABLE, "0", "1 = enable !knifefight in 1v1, 0 = disable");
    CvarMinTime = AutoExecConfig_CreateConVar(CVAR_MINTIME, "0", "minimum remaining round time in seconds for knife fight (time will be added to reach this value)")
    CvarMinHealth = AutoExecConfig_CreateConVar(CVAR_MINHEALTH, "0", "minimum remaining player health for knife fight (health will be added to reach this value)")
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // init hooks
    HookConVarChange(CvarDebug, CvarsUpdated);
    HookConVarChange(CvarEnable, CvarsUpdated);
    HookConVarChange(CvarMinTime, CvarsUpdated);
    HookConVarChange(CvarMinHealth, CvarsUpdated);
    RegConsoleCmd(CMD_KNIFEFIGHT, KnifeFightCmd, "vote to knife fight in a 1v1");
    RegConsoleCmd(CMD_KNIFEFIGHT_SHORT, KnifeFightCmd, "vote to knife fight in a 1v1");
    HookEvent("player_death", OnPlayerDeath, EventHookMode_PostNoCopy);
    HookEvent("round_end", OnRoundEnd, EventHookMode_PostNoCopy);
    HookEvent("round_start", OnRoundStart, EventHookMode_PostNoCopy);

    // load config
    SetCvars();

    // initialize plugin state
    ReinitState(true);
}

void ReinitState(bool check) {
    if (State == STATE_KNIFE) {
        EndKnifeFight();
    }

    State = STATE_NOT_1v1;
    FOR_EACH_INDEX(i) {
        Voted[i] = 0;
    }

    if (check && Enabled) {
        Check1v1();
    }
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

    if (Enabled && !prevEnabled) {
        ReinitState(true);
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
    PrintToChatAll("%s has agreed to a knife fight!", name);
    if (!Voted[other_slot]) {
        PrintHintText(Entity[other_slot], "%s has challenged you to a knife fight! Type !%s to accept.", name, CMD_KNIFEFIGHT_SHORT);
    }
    else {
        StartKnifeFight();
    }

    return Plugin_Handled;
}

void StartKnifeFight() {
    State = STATE_KNIFE;
    #define msg "Let the knife fight begin!"
    PrintToChatAll(msg);
    FOR_EACH_INDEX(i) {
        PrintHintText(Entity[i], msg);
    }
    #undef msg

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

    int roundTimeLimit = GameRules_GetProp("m_iRoundTime", 4, 0);
    int timeRemaining = RoundStartTime + roundTimeLimit - GetTime();
    if (Debug) {
        LogMessage("round time limit %d", roundTimeLimit);
        LogMessage("round start time %d", RoundStartTime);
        LogMessage("current time %d", GetTime());
        LogMessage("remaining round time was %d", timeRemaining);
    }
    
    if (timeRemaining < MinTime) {
        if (RoundStartTime > 0) {
            roundTimeLimit += (MinTime - timeRemaining);
            if (Debug) {
                LogMessage("setting round time to %d", roundTimeLimit);
            }
            GameRules_SetProp("m_iRoundTime", roundTimeLimit, 4, 0, true);
        }
        else {
            LogMessage("RoundStartTime was not set, not extending the round");
        }
    }
}

void EndKnifeFight() {
    FOR_EACH_INDEX(i) {
        SDKUnhook(Entity[i], SDKHook_OnTakeDamage, OnTakeDamage);
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

public Action OnTakeDamage(int victim, int& attacker, int &inflictor, float& damage, int& damagetype, int& weapon, float damageForce[3], float damagePosition[3])
{
    if (!Enabled || State != STATE_KNIFE) {
        return Plugin_Continue;
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
    else if (State == STATE_1v1) {
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
    RoundStartTime = GetTime() - FindConVar("mp_freezetime").IntValue;
}
