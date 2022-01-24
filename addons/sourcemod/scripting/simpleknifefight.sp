#include <sourcemod>
#include <sdkhooks>
#include <autoexecconfig>

#pragma newdecls required

public Plugin myinfo =
{
    name = "simpleknifefight",
    author = "tmick0",
    description = "Allows players to choose to knife fight in a 1v1",
    version = "0.1",
    url = "github.com/tmick0/sm_simpleknifefight"
};

#define CVAR_ENABLE "sm_simpleknifefight_enable"
#define CVAR_DEBUG "sm_simpleknifefight_debug"

#define CMD_KNIFEFIGHT "knifefight"
#define CMD_KNIFEFIGHT_SHORT "kf"

#define ENTITY_NAME_MAX 128

#define KNIFE_GENERIC "weapon_knife"
#define KNIFE_BAYONET "weapon_bayonet"
#define KNIFE_MELEE "weapon_melee"
#define KNIFE_GENERIC_LEN 12

int Enabled;
int Debug;
int State;
int Voted[2];
int Entity[2];

#define INDEX_T 0
#define INDEX_CT 1

#define TEAM_T 2
#define TEAM_CT 3

#define STATE_NOT_1v1 0
#define STATE_1v1 1
#define STATE_KNIFE 2

ConVar CvarEnable;
ConVar CvarDebug;

public void OnPluginStart() {
    // init config    
    AutoExecConfig_SetCreateDirectory(true);
    AutoExecConfig_SetCreateFile(true);
    AutoExecConfig_SetFile("plugin_simpleknifefight");
    CvarDebug = CreateConVar(CVAR_DEBUG, "0", "1 = enable debug output, 0 = disable");
    CvarEnable = CreateConVar(CVAR_ENABLE, "0", "1 = enable !knifefight in 1v1, 0 = disable");
    AutoExecConfig_ExecuteFile();
    AutoExecConfig_CleanFile();

    // init hooks
    HookConVarChange(CvarDebug, CvarsUpdated);
    HookConVarChange(CvarEnable, CvarsUpdated);
    RegConsoleCmd(CMD_KNIFEFIGHT, KnifeFightCmd, "vote to knife fight in a 1v1");
    RegConsoleCmd(CMD_KNIFEFIGHT_SHORT, KnifeFightCmd, "vote to knife fight in a 1v1");
    HookEvent("player_death", OnPlayerDeath, EventHookMode_PostNoCopy);
    HookEvent("round_end", OnRoundEnd, EventHookMode_PostNoCopy);

    // load config
    SetCvars();

    // initialize plugin state
    ReinitState(true);
}

void ReinitState(bool check) {
    State = STATE_NOT_1v1;
    Voted[INDEX_T] = 0;
    Voted[INDEX_CT] = 0;
    Entity[INDEX_T] = -1;
    Entity[INDEX_CT] = -1;

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
        ReplyToCommand(client, "The %s command is only for the players who are alive", CMD_KNIFEFIGHT);
        return Plugin_Handled;
    }

    if (Voted[slot]) {
        ReplyToCommand(client, "You already voted");
        return Plugin_Handled;
    }

    Voted[slot] = 1;

    char name[128];
    GetClientName(client, name, sizeof(name))
    
    PrintToChatAll("%s has agreed to a knife fight!", name);
    if (!Voted[other_slot]) {
        PrintHintText(Entity[other_slot], "%s has challenged you to a knife fight! Type !%s (or !%s) to accept.", name, CMD_KNIFEFIGHT, CMD_KNIFEFIGHT_SHORT);
    }
    else {
        State = STATE_KNIFE;
        #define msg "Let the knife fight begin!"
        PrintToChatAll(msg);
        PrintHintText(Entity[INDEX_T], msg);
        PrintHintText(Entity[INDEX_CT], msg);
        #undef msg
    }

    return Plugin_Handled;
}

void Check1v1() {
    if (!Enabled || State != STATE_NOT_1v1) {
        return;
    }

    Entity[INDEX_T] = -1;
    Entity[INDEX_CT] = -1;

    for (int i = 1; i <= MaxClients; i++) {
        if (IsClientConnected(i) && IsClientInGame(i) && IsPlayerAlive(i)) {
            int team = GetClientTeam(i);
            if (team == TEAM_T) {
                team = INDEX_T;
            }
            else if (team == TEAM_CT) {
                team = INDEX_CT;
            }
            else {
                continue;
            }

            if(Entity[team] != -1) {
                return;
            }

            Entity[team] = i;
        }
	}

    if (Entity[INDEX_T] != -1 && Entity[INDEX_CT] != -1) {
        State = STATE_1v1;
        #define msg "It's 1v1! Type !%s (or !%s) to knife fight!"
        PrintHintText(Entity[INDEX_T], msg, CMD_KNIFEFIGHT, CMD_KNIFEFIGHT_SHORT);
        PrintToChat(Entity[INDEX_T], msg, CMD_KNIFEFIGHT, CMD_KNIFEFIGHT_SHORT);
        PrintHintText(Entity[INDEX_CT], msg, CMD_KNIFEFIGHT, CMD_KNIFEFIGHT_SHORT);
        PrintToChat(Entity[INDEX_CT], msg, CMD_KNIFEFIGHT, CMD_KNIFEFIGHT_SHORT);
        #undef msg
    }
}

public Action OnPlayerRunCmd(int client, int& buttons, int& impulse, float vel[3], float angles[3], int& weapon, int& subtype, int& cmdnum, int& tickcount, int& seed, int mouse[2]) {
    if (!Enabled || State != STATE_KNIFE) {
        return Plugin_Continue;
    }

    if (client != Entity[INDEX_T] && client != Entity[INDEX_CT]) {
        return Plugin_Continue;
    }

    if (!(buttons & (IN_ATTACK | IN_ATTACK2))) {
        return Plugin_Continue;
    }

    char entity[ENTITY_NAME_MAX];
    GetClientWeapon(client, entity, ENTITY_NAME_MAX);

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

    if (!allow) {
        if (Debug) {
            LogMessage("blocking use of %s by client %d", entity, client);
        }
        buttons &= ~(IN_ATTACK | IN_ATTACK2);
        return Plugin_Changed;
    }

    if (Debug) {
        LogMessage("allowing use of %s by client %d", entity, client);
    }

    return Plugin_Handled;
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
