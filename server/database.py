import os
import psycopg2
import psycopg2.extras
from psycopg2 import pool
from dotenv import load_dotenv

load_dotenv()


class _PooledConnection:
    def __init__(self, connection, connection_pool):
        self._connection = connection
        self._connection_pool = connection_pool
        self._closed = False

    def __getattr__(self, name):
        return getattr(self._connection, name)

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            self._connection.rollback()
        except psycopg2.Error:
            pass
        self._connection_pool.putconn(self._connection)


class DatabasePool:
    _instance = None

    def __new__(cls):
        if cls._instance is None:
            cls._instance = super().__new__(cls)
            cls._instance._connection_pool = None
        return cls._instance

    def get_connection(self):
        if self._connection_pool is None:
            self._connection_pool = pool.ThreadedConnectionPool(
                minconn=int(os.getenv("DB_POOL_MIN", "1")),
                maxconn=int(os.getenv("DB_POOL_MAX", "10")),
                host=os.getenv("DB_HOST", "localhost"),
                database=os.getenv("DB_NAME", "ensemblesync"),
                user=os.getenv("DB_USER"),
                password=os.getenv("DB_PASSWORD")
            )
        return _PooledConnection(
            self._connection_pool.getconn(),
            self._connection_pool,
        )


def get_db():
    return DatabasePool().get_connection()
