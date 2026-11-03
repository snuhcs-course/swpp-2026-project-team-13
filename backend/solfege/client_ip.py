"""Client IP resolution for attempt limits. Forwarding headers count only from trusted proxies."""
import ipaddress
import logging

from django.conf import settings

logger = logging.getLogger(__name__)


def parse_ip(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError:
        return None
    return getattr(address, "ipv4_mapped", None) or address


def from_trusted_proxy(request):
    # Decided by the connecting address, never by whether a forwarding header is present.
    address = parse_ip(request.META.get("REMOTE_ADDR", ""))
    return address is not None and any(address in network for network in settings.TRUSTED_PROXIES)


def client_ip_key(request):
    """The value attempt limits count by: one IPv4 address or one IPv6 /64 network."""
    remote = request.META.get("REMOTE_ADDR", "")
    address = parse_ip(remote)
    if from_trusted_proxy(request):
        forwarded = parse_ip(request.headers.get(settings.CLIENT_IP_HEADER, "").strip())
        if forwarded is None:
            logger.warning("Trusted proxy sent no usable client IP header; counting by REMOTE_ADDR.")
        else:
            address = forwarded
    if address is None:
        return remote
    if address.version == 6:
        return str(ipaddress.IPv6Network((int(address) >> 64 << 64, 64)))
    return str(address)
