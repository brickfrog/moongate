import logging

log = logging.getLogger(__name__)


def get_profile(request):
    log.info("profile requested auth=%s", request.headers["authorization"])
    return lookup_user(request.headers["authorization"])
