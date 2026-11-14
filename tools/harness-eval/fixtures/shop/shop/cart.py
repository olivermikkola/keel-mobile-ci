"""The shopping cart."""
from shop.pricing import apply_discount, format_price


def calc(price, quantity):
    """Price of one cart line."""
    return price * quantity


class Cart:
    def __init__(self):
        self.lines = []
        self.discount_percent = 0

    def add_item(self, name, price, quantity=1):
        if quantity < 1:
            raise ValueError("quantity must be at least 1")
        self.lines.append({"name": name, "price": price, "quantity": quantity})

    def remove_item(self, name):
        self.lines = [line for line in self.lines if line["name"] != name]

    def total(self):
        subtotal = sum(calc(line["price"], line["quantity"]) for line in self.lines)
        return apply_discount(subtotal, self.discount_percent)

    def summary(self):
        rows = [f'{line["name"]} x{line["quantity"]}: {format_price(calc(line["price"], line["quantity"]))}'
                for line in self.lines]
        rows.append(f"Total: {format_price(self.total())}")
        return "\n".join(rows)
