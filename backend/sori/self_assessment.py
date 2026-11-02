"""Pure validation for coarse, self-reported observations, not error attribution."""
ERROR_TYPES = ("pitch", "rhythm", "other")


def normalize_errors(value, measure_count):
    if not isinstance(value, list) or len(value) > measure_count:
        raise ValueError("errors must be a list of distinct measures")
    seen, result = set(), []
    for item in value:
        if not isinstance(item, dict) or set(item) != {"measure", "types"}:
            raise ValueError("each error needs measure and types")
        measure, types = item["measure"], item["types"]
        if type(measure) is not int or not 1 <= measure <= measure_count or measure in seen:
            raise ValueError("invalid or duplicate measure")
        if not isinstance(types, list) or not types or len(types) > len(ERROR_TYPES) or any(not isinstance(t, str) or t not in ERROR_TYPES for t in types) or len(set(types)) != len(types):
            raise ValueError("invalid error types")
        seen.add(measure)
        result.append({"measure": measure, "types": [t for t in ERROR_TYPES if t in types]})
    return sorted(result, key=lambda row: row["measure"])
