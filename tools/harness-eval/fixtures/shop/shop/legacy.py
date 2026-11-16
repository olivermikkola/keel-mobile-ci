"""Old CSV export. Nothing uses this any more."""


def export_csv(cart):
    return "\n".join(f'{line["name"]},{line["price"]},{line["quantity"]}' for line in cart.lines)
