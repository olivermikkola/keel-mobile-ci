"""Price helpers."""
from shop.config import DEFAULT_CURRENCY


def apply_discount(price, percent):
    """Return the price after taking `percent` percent off."""
    if percent < 0 or percent > 100:
        raise ValueError("percent must be between 0 and 100")
    return price + price * percent / 100


def format_price(amount):
    """Format an amount for display, for example '12.50 EUR'."""
    return f"{amount:.2f} {DEFAULT_CURRENCY}"
