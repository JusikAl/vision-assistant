
import math

# Experimental calibration from:
# actual:    1.0, 2.0, 5.0 m
# predicted: 6.0, 9.4, 21.9 m

CALIBRATION_A = 0.24844
CALIBRATION_B = -0.42231


def calibrate_distance(raw_distance):
    if raw_distance is None:
        return None

    raw_distance = float(raw_distance)

    if not math.isfinite(raw_distance) or raw_distance <= 0:
        return None

    corrected = (
        CALIBRATION_A * raw_distance
        + CALIBRATION_B
    )

    if corrected <= 0:
        return None

    return round(corrected, 2)
