"""stac_fastapi: core lucenia/ opensearch module."""

from setuptools import find_namespace_packages, setup

with open("README.md") as f:
    desc = f.read()

install_requires = [
    "fastapi-slim",
    "attrs>=23.2.0",
    "pydantic[dotenv]",
    "stac_pydantic>=3",
    "stac-fastapi.types==3.0.0",
    "stac-fastapi.api==3.0.0",
    "stac-fastapi.extensions==3.0.0",
    "orjson",
    "overrides",
    "geojson-pydantic",
    "pygeofilter==0.2.1",
    "typing_extensions==4.8.0",
    "jsonschema",
]

setup(
    name="stac-fastapi.core",
    description="Core library for the ES and OS stac-fastapi backends.",
    long_description=desc,
    long_description_content_type="text/markdown",
    python_requires=">=3.8",
    classifiers=[
        "Intended Audience :: Developers",
        "Intended Audience :: Information Technology",
        "Intended Audience :: Science/Research",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9",
        "Programming Language :: Python :: 3.10",
        "Programming Language :: Python :: 3.11",
        "Programming Language :: Python :: 3.12",
        "License :: OSI Approved :: MIT License",
    ],
    license="MIT",
    packages=find_namespace_packages(),
    zip_safe=False,
    install_requires=install_requires,
)
