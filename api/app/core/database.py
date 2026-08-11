import asyncpg
from app.core.config import (
    postgres_docker_name,
    postgres_port_number,
    postgres_user,
    postgres_password,
    postgres_db,
)


async def create_pool():
    return await asyncpg.create_pool(
        host=postgres_docker_name,
        port=postgres_port_number,
        user=postgres_user,
        password=postgres_password,
        database=postgres_db,
        min_size=1,
        max_size=3,
        command_timeout=5.0,
    )
