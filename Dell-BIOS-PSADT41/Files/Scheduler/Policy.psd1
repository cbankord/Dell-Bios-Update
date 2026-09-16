@{
    Schema = 2
    WindowHours = 72 # 1-168; persisted at enrollment. Later changes never extend an existing deadline.
    ReminderHours = 4
    PreparationLeadMinutes = 30
    FinalWarningMinutes = 15
    SafetyRetryMinutes = 5
    # V2 owns restarts. Configure this Win32 app as 'No specific action' in Intune.
}
