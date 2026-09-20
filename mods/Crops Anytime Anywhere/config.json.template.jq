def string_array:
    if type == "array" then all(.[]; type == "string" and length > 0) else false end;
def seasons:
    string_array and all(.[]; ascii_downcase | IN("spring", "summer", "fall", "winter"));
def locations:
    string_array and all(.[]; ascii_downcase | IN("indoors", "outdoors") | not);
def canonical_seasons:
    map({"spring":"Spring", "summer":"Summer", "fall":"Fall", "winter":"Winter"}[ascii_downcase]) | unique;

if ([.PlantRules[0].CanPlant, .PlantRules[0].CanGrowOutOfSeason,
     .PlantRules[0].UseFruitTreesSeasonalSprites, .TillableRules[0].Dirt,
     .TillableRules[0].Grass, .TillableRules[0].Stone, .TillableRules[0].Other]
    | all(.[]; type == "boolean")) | not
then error("Crops switches must be JSON booleans")
elif ([.PlantRules[0].ForSeasons, .TillableRules[0].ForSeasons] | all(.[]; seasons)) | not
then error("Crops seasons must be JSON arrays of Spring, Summer, Fall and/or Winter")
elif ([.PlantRules[0].ForLocations, .TillableRules[0].ForLocations] | all(.[]; locations)) | not
then error("Crops locations must be JSON arrays of internal names; avoid the upstream inverted Indoors/Outdoors aliases")
elif ([.PlantRules[0].ForLocationContexts, .TillableRules[0].ForLocationContexts] | all(.[]; string_array)) | not
then error("Crops location contexts must be JSON arrays of nonempty names")
else
    # Upstream treats an empty season selector as all seasons. No selected
    # seasons in our controls must instead produce no overrides.
    .PlantRules |= map(select(.ForSeasons | length > 0) | .ForSeasons |= canonical_seasons) |
    .TillableRules |= map(select(.ForSeasons | length > 0) | .ForSeasons |= canonical_seasons)
end
