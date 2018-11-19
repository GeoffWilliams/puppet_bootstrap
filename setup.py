import setuptools

with open("README.md", "r") as fh:
    long_description = fh.read()
    setuptools.setup(
        name='puppet_bootstrap',
        version='0.1.0',
        scripts=['puppet_bootstrap'],
        author="Geoff Williams",
        author_email="geoff@declarativesystems.com",
        description="A Docker and AWS utility package",
        long_description=long_description,
        long_description_content_type="text/markdown",
        url="https://github.com/javatechy/dokr",
        packages=setuptools.find_packages(),
        classifiers=[
            "Programming Language :: Python :: 2",
            "License :: OSI Approved :: MIT License",
            "Operating System :: OS Independent",
        ],
    )
