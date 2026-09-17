# MedelaBIOS-FileVersion: 4.0.0
@{
    Schema = 3
    AllowScheduleLater = $true # Installation scheduling only; deferrals/restart warning remain independent.
    WindowHours = 72
    ReminderHours = 4 # Minimum between prompts; actual retries are owned by Intune.
    PromptTimeoutMinutes = 10
    RestartCountdownMinutes = 60
    RestartReminderMinutes = 15
}
