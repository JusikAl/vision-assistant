
import unittest

from depth_stabilizer import DepthStabilizer


def make_detection(distance, bbox=None):
    return {
        "class_name": "Person",
        "bbox": bbox or [100, 100, 300, 400],
        "calibrated_distance_m": distance,
        "distance_m": distance,
    }


class TestDepthStabilizer(unittest.TestCase):

    def setUp(self):
        self.stabilizer = DepthStabilizer()

    def update(self, distance, bbox=None):
        detection = make_detection(distance, bbox)
        return self.stabilizer.update([detection])[0]

    def test_first_detection(self):
        result = self.update(2.0)

        self.assertEqual(result["distance_m"], 2.0)
        self.assertEqual(result["track_id"], 1)

    def test_approaching_obstacle(self):
        self.update(2.0)
        result = self.update(1.0)

        self.assertAlmostEqual(
            result["distance_m"], 1.25
        )

    def test_receding_obstacle(self):
        self.update(1.0)
        result = self.update(2.0)

        self.assertAlmostEqual(
            result["distance_m"], 1.25
        )

    def test_stable_distance(self):
        self.update(1.5)

        for _ in range(10):
            result = self.update(1.5)

        self.assertAlmostEqual(
            result["distance_m"], 1.5
        )

    def test_track_id_preserved(self):
        first = self.update(2.0)
        second = self.update(
            1.9, [105, 105, 305, 405]
        )

        self.assertEqual(
            first["track_id"],
            second["track_id"]
        )

    def test_invalid_distance(self):
        self.update(2.0)
        result = self.update(None)

        self.assertIsNone(result["distance_m"])

    def test_object_tracking_loss(self):
        first = self.update(2.0)
        second = self.update(
            1.0, [500, 500, 700, 800]
        )

        self.assertNotEqual(
            first["track_id"],
            second["track_id"]
        )

    def test_invalid_values(self):
        for value in [float("nan"), -1.0, 0.0]:
            result = self.update(value)
            self.assertIsNone(result["distance_m"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
