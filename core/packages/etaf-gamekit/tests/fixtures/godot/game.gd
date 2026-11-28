extends Node
# SPDX-License-Identifier: GPL-3.0-or-later
# Controlled public-protocol peer, not a game application.
var count: int = 0

func capabilities() -> Array:
	return ["increment"]

func command(operation: String, args: Dictionary) -> String:
	if operation != "increment":
		return "Unknown operation"
	var amount = args.get("amount")
	if not (amount is int or amount is float) or not is_finite(float(amount)):
		return "Amount must be an integer"
	if floor(float(amount)) != float(amount) or abs(float(amount)) > 100:
		return "Amount must be an integer from -100 to 100"
	count += int(amount)
	return ""

func observe() -> Dictionary:
	return {"schema": "counter/1", "count": count}
