"""Offline reservation-price reference; illustrative inputs, not a fitted model.

Amounts are WETH, annual rates are fractions, remaining time is days. Costs are
present-value amounts paid by the maker. Do not include the same funding cost
in both the annual rate and capacity charge. Outputs are conservative WETH wei.
This does not publish NAV, authorize a quote, or promise resale liquidity.
"""

import argparse
import json
from decimal import Decimal, ROUND_FLOOR, localcontext


def nonnegative(value):
    result = Decimal(str(value))
    if not result.is_finite() or result < 0:
        raise ValueError("inputs must be finite and nonnegative")
    return result


def reservation_price(data):
    """Discount joint recovery/time scenarios, then deduct today's cost buffers.

    E[recovery / (1 + rate * days / 365)] retains correlation; discounting the
    average recovery at the average time generally gives a different answer.
    Scenario probabilities must sum to one. Zero means decline, not a free fill.
    """
    with localcontext() as context:
        context.prec = 80
        rate = nonnegative(data["annual_funding_rate"])
        probability = Decimal(0)
        present_value = Decimal(0)
        for scenario in data["scenarios"]:
            weight = nonnegative(scenario["probability"])
            recovery = nonnegative(scenario["recovery_weth"])
            days = nonnegative(scenario["remaining_days"])
            probability += weight
            present_value += weight * recovery / (1 + rate * days / 365)
        if probability != 1:
            raise ValueError("scenario probabilities must sum exactly to one")
        deductions = sum(nonnegative(data[key]) for key in (
            "operating_costs_weth", "risk_buffer_weth",
            "capacity_charge_weth", "minimum_profit_weth",
        ))
        maximum = max(Decimal(0), present_value - deductions)
        wei = (maximum * 10**18).to_integral_value(rounding=ROUND_FLOOR)
        return {
            "model": "joint-simple-discount-v1",
            "holding_present_value_weth": str(present_value),
            "maximum_maker_payment_wei": int(wei),
            "decline": wei == 0,
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="JSON file containing explicitly assumed scenarios")
    args = parser.parse_args()
    with open(args.input, encoding="utf-8") as source:
        print(json.dumps(reservation_price(json.load(source, parse_float=Decimal)), indent=2))
