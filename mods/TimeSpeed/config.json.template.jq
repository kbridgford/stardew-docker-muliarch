def valid_speed:
    # TimeSpeed multiplies integer milliseconds/minute by ten for its int tick interval.
    if type == "number" then . >= 0.001 and . <= 214748.364 else false end;
def valid_time:
    . == null or
    (if type == "number" then . == floor and . >= 600 and . <= 2600 and . % 100 < 60 else false end);

if ([.EnableOnFestivalDays, .LocationNotify, .LetFarmhandsManageTime,
     .FreezeTime.PassOut, .FreezeTime.Indoors, .FreezeTime.Outdoors,
     .FreezeTime.Mines, .FreezeTime.SkullCavern, .FreezeTime.VolcanoDungeon]
    | all(.[]; type == "boolean")) | not
then error("TimeSpeed switches must be JSON booleans")
elif ([.SecondsPerMinute.Indoors, .SecondsPerMinute.Outdoors, .SecondsPerMinute.Mines,
       .SecondsPerMinute.SkullCavern, .SecondsPerMinute.VolcanoDungeon] | all(.[]; valid_speed)) | not
then error("TimeSpeed seconds per minute must be numbers in 0.001..214748.364; use freeze switches instead of zero")
elif (.FreezeTime.AnywhereAtTime | valid_time) | not
then error("TimeSpeed freeze time must be null or an integer HHMM from 600 to 2600 with minutes below 60")
elif (.Keys | all(.[]; type == "string")) | not
then error("TimeSpeed key bindings must be strings")
else .
end
