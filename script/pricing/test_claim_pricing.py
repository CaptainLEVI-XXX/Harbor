"""Deterministic reference checks; no historical calibration is implied."""

import unittest
from decimal import Decimal

from claim_pricing import reservation_price


def inputs():
    return {
        "annual_funding_rate": "0.1",
        "operating_costs_weth": "0",
        "risk_buffer_weth": "0",
        "capacity_charge_weth": "0",
        "minimum_profit_weth": "0",
        "scenarios": [{"probability": "1", "recovery_weth": "1", "remaining_days": "365"}],
    }


class PricingTest(unittest.TestCase):
    def test_years_are_days_divided_by_365_and_payment_rounds_down(self):
        self.assertEqual(reservation_price(inputs())["maximum_maker_payment_wei"], 909090909090909090)

    def test_zero_wait_and_present_value_costs(self):
        data = inputs()
        data["scenarios"][0]["remaining_days"] = "0"
        data["operating_costs_weth"] = "0.01"
        self.assertEqual(reservation_price(data)["maximum_maker_payment_wei"], 990000000000000000)

    def test_joint_scenarios_not_average_time(self):
        data = inputs()
        data["scenarios"] = [
            {"probability": "0.5", "recovery_weth": "1", "remaining_days": "0"},
            {"probability": "0.5", "recovery_weth": "0", "remaining_days": "365"},
        ]
        self.assertEqual(reservation_price(data)["maximum_maker_payment_wei"], 500000000000000000)

    def test_costs_or_zero_recovery_can_require_declining(self):
        data = inputs()
        data["risk_buffer_weth"] = "2"
        self.assertTrue(reservation_price(data)["decline"])
        data["risk_buffer_weth"] = "0"
        data["scenarios"][0]["recovery_weth"] = "0"
        self.assertTrue(reservation_price(data)["decline"])

    def test_invalid_domains_and_probabilities_rejected(self):
        for bad in ("-1", "NaN", "Infinity"):
            data = inputs()
            data["annual_funding_rate"] = bad
            with self.assertRaises(ValueError):
                reservation_price(data)
        data = inputs()
        data["scenarios"][0]["probability"] = "0.9"
        with self.assertRaises(ValueError):
            reservation_price(data)

    def test_longer_wait_or_larger_buffer_never_increases_bid(self):
        data = inputs()
        previous = reservation_price(data)["maximum_maker_payment_wei"]
        for days in range(366, 730):
            data["scenarios"][0]["remaining_days"] = str(days)
            data["capacity_charge_weth"] = str(Decimal(days - 365) / 100000)
            current = reservation_price(data)["maximum_maker_payment_wei"]
            self.assertLessEqual(current, previous)
            previous = current
