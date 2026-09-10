"""Decimal reference for Harbor standing pricing; illustrative, not calibrated.

Amounts are WETH, factors and annual rates are fractions, time is remaining days.
Only the reusable discount is published. Contracts independently obtain FACE,
inventory, cash and risk limits. This reference is not an execution authorization,
NAV publisher, acceptance model or bit-for-bit Solidity emulator.
"""

import argparse
import json
from decimal import Decimal, ROUND_FLOOR, ROUND_CEILING, localcontext


def nonnegative(value):
    result = Decimal(str(value))
    if not result.is_finite() or result < 0:
        raise ValueError("inputs must be finite and nonnegative")
    return result


def reservation_price(data):
    """Joint discounted recovery plus the difference of inventory potentials.

    The quantized discount is reused on both sides. Bids round down; asks round
    up. The Solidity kernel additionally bounds intermediate approximation error.
    A null side means decline, never a free fill. External fees are separate.
    """
    with localcontext() as context:
        context.prec = 80
        rate = nonnegative(data["annual_funding_rate"])
        probability = Decimal(0)
        factor = Decimal(0)
        for scenario in data["scenarios"]:
            weight = nonnegative(scenario["probability"])
            recovery = nonnegative(scenario["recovery_fraction"])
            days = nonnegative(scenario["remaining_days"])
            if weight > 1 or recovery > 1:
                raise ValueError("probabilities and recovery fractions cannot exceed one")
            probability += weight
            factor += weight * recovery / (1 + rate * days / 365)
        if probability != 1:
            raise ValueError("scenario probabilities must sum exactly to one")
        wad = Decimal(10**18)
        discount_wad = int((factor * wad).to_integral_value(rounding=ROUND_FLOOR))
        discount = Decimal(discount_wad) / wad
        e = nonnegative(data["nominal_entitlement_weth"])
        x = nonnegative(data["exposure_weth"])
        k = nonnegative(data["capacity_weth"])
        target = nonnegative(data["target_utilization"])
        kappa = nonnegative(data["kappa"])
        buy_margin = nonnegative(data["buy_margin"])
        sell_margin = nonnegative(data["sell_margin"])
        buy_cost = nonnegative(data["buy_cost_weth"])
        sell_cost = nonnegative(data["sell_cost_weth"])
        if not (1 <= k <= 10**9 and 0 < e <= 10**9 and x <= 2*k
                and target <= Decimal("0.9") and kappa <= Decimal("0.01")
                and max(buy_margin, sell_margin) <= Decimal("0.05")
                and max(buy_cost, sell_cost) <= 1):
            raise ValueError("outside the MVP curve domain")

        def potential(face):
            excess = max(Decimal(0), face/k - target)
            return kappa*k*excess**3 / (3*(1-target)**2)

        gross_bid = None
        net_ask = None
        admissible = (Decimal("0.5") <= discount <= 1
                      and discount >= buy_margin + kappa + Decimal("0.1"))
        if admissible and x + e <= k:
            bid = e*(discount-buy_margin) - buy_cost - (potential(x+e)-potential(x))
            if bid > 0:
                gross_bid = int((bid*wad).to_integral_value(rounding=ROUND_FLOOR)) or None
        slope = kappa * max(Decimal(0), x/k-target)**2 / (1-target)**2
        if admissible and e <= x and discount+sell_margin >= slope + Decimal("0.1"):
            ask = e*(discount+sell_margin) + sell_cost - (potential(x)-potential(x-e))
            if ask > 0:
                net_ask = int((ask*wad).to_integral_value(rounding=ROUND_CEILING))
        return {
            "model": "joint-discount-inventory-potential-v1",
            "discount_wad": discount_wad,
            "holding_present_value_weth": str(e*discount),
            "gross_vault_buy_payment_wei": gross_bid,
            "net_vault_sell_receipt_wei": net_ask,
            "math_admissible": admissible,
            "note": "Real quotes must additionally pass contract cash, inventory, public-price and risk gates.",
        }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", help="JSON containing explicitly assumed scenarios and state")
    args = parser.parse_args()
    with open(args.input, encoding="utf-8") as source:
        print(json.dumps(reservation_price(json.load(source, parse_float=Decimal)), indent=2))
