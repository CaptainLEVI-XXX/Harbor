"""Small independent reference checks; no historical calibration is implied."""

import unittest
from claim_pricing import reservation_price


def inputs():
    return {
        "annual_funding_rate": "0.1",
        "nominal_entitlement_weth": "1",
        "exposure_weth": "100",
        "capacity_weth": "1000",
        "target_utilization": "0.6",
        "kappa": "0.0025",
        "buy_margin": "0",
        "sell_margin": "0",
        "buy_cost_weth": "0",
        "sell_cost_weth": "0",
        "scenarios": [{"probability": "1", "recovery_fraction": "1", "remaining_days": "365"}],
    }


class PricingTest(unittest.TestCase):
    def test_years_are_days_divided_by_365_and_factor_rounds_down(self):
        result = reservation_price(inputs())
        self.assertEqual(result["discount_wad"], 909090909090909090)
        self.assertEqual(result["gross_vault_buy_payment_wei"], result["discount_wad"])

    def test_zero_wait_costs_and_margins_are_separate_from_fees(self):
        data = inputs()
        data["scenarios"][0]["remaining_days"] = "0"
        data["buy_cost_weth"] = data["sell_cost_weth"] = "0.01"
        data["buy_margin"] = data["sell_margin"] = "0.02"
        result = reservation_price(data)
        self.assertEqual(result["gross_vault_buy_payment_wei"], 970000000000000000)
        self.assertEqual(result["net_vault_sell_receipt_wei"], 1030000000000000000)

    def test_joint_scenarios_not_average_time(self):
        data = inputs()
        data["scenarios"] = [
            {"probability": "0.5", "recovery_fraction": "1", "remaining_days": "0"},
            {"probability": "0.5", "recovery_fraction": "0", "remaining_days": "365"},
        ]
        self.assertEqual(reservation_price(data)["discount_wad"], 500000000000000000)

    def test_capacity_or_costs_decline_instead_of_free_trade(self):
        data = inputs()
        data["exposure_weth"] = "1000"
        self.assertIsNone(reservation_price(data)["gross_vault_buy_payment_wei"])
        data["exposure_weth"] = "0"
        data["buy_cost_weth"] = "1"
        result = reservation_price(data)
        self.assertIsNone(result["gross_vault_buy_payment_wei"])
        self.assertIsNone(result["net_vault_sell_receipt_wei"])

    def test_invalid_domains_and_probabilities_rejected(self):
        for bad in ("-1", "NaN", "Infinity"):
            data = inputs()
            data["annual_funding_rate"] = bad
            with self.assertRaises(ValueError):
                reservation_price(data)
        for key, bad in (("capacity_weth", "0"), ("target_utilization", "1")):
            data = inputs()
            data[key] = bad
            with self.assertRaises(ValueError):
                reservation_price(data)
        data = inputs()
        data["scenarios"][0]["probability"] = "0.9"
        with self.assertRaises(ValueError):
            reservation_price(data)

    def test_more_exposure_lowers_bid_and_potential_cancels_on_roundtrip(self):
        data = inputs()
        data["buy_margin"] = data["sell_margin"] = "0.002"
        before = reservation_price(data)["gross_vault_buy_payment_wei"]
        for exposure in range(601, 999):
            data["exposure_weth"] = str(exposure)
            bid = reservation_price(data)["gross_vault_buy_payment_wei"]
            self.assertLessEqual(bid, before)
            data["exposure_weth"] = str(exposure + 1)
            ask = reservation_price(data)["net_vault_sell_receipt_wei"]
            self.assertGreaterEqual(ask - bid, 4000000000000000)
            self.assertLessEqual(ask - bid, 4000000000000002)
            before = bid
