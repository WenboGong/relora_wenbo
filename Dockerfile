# syntax=docker/dockerfile:1
# FROM ce931603eb4f4dac978e05ee180b8e46.azurecr.io/causica/cuda12base:0.1.0 as base
FROM mcr.microsoft.com/azureml/openmpi4.1.0-cuda11.8-cudnn8-ubuntu22.04:20240712.v1 as base
USER root

# remove the unused conda environments
RUN conda install anaconda-clean  && \
    anaconda-clean -y && \
    rm -rf /opt/miniconda

RUN apt-get update && \
    apt-get install -y graphviz-dev python3-dev python3-pip && \
    apt-get clean -y && \
    rm -rf /var/lib/apt/lists/* && \
    ln -s /usr/bin/python3 /usr/bin/python && \
    python -c 'import sys; assert sys.version_info[:2] == (3, 10)'

ENV POETRY_CACHE_DIR="/root/.cache/pypoetry" \
    POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_VIRTUALENVS_IN_PROJECT=false \
    POETRY_VERSION=1.8.2
RUN python -m pip install poetry==$POETRY_VERSION

# Install dependencies separately to allow dependency caching
# Note: Temporarily create dummy content to allow installing the
#       nested dependencies.
WORKDIR /workspaces/relora
COPY poetry.lock pyproject.toml .
RUN --mount=type=cache,target=/root/.cache/pypoetry,sharing=locked \
    poetry install

COPY . /workspaces/relora



FROM base as deploy
COPY . /workspaces/relora
RUN --mount=type=cache,target=/root/.cache/pypoetry,sharing=locked \
    poetry install --only main

FROM singularitybase.azurecr.io/validations/base/singularity-tests:20230602T145041989 as singularity-validator
FROM singularitybase.azurecr.io/installer/base/singularity-installer:20230602T144853997 as singularity-installer

FROM deploy as deploy-singularity
# Install components required for running this image in Singularity
COPY --from=singularity-installer /installer /opt/microsoft/_singularity/installations/
RUN /opt/microsoft/_singularity/installations/singularity/installer.sh

# Validate with singularity
COPY --from=singularity-validator /validations /opt/microsoft/_singularity/validations/
ENV SINGULARITY_IMAGE_ACCELERATOR="NVIDIA"
RUN /opt/microsoft/_singularity/validations/validator.sh


FROM base as dev
# Install development shell and utils
COPY .devcontainer/.p10k.zsh /root/
RUN <<EOT
    apt-get update
    apt-get install -y zsh ruby-full moby-cli
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash
    apt-get clean -y
    rm -rf /var/lib/apt/lists/*
    git clone --depth=1 https://github.com/scmbreeze/scm_breeze.git ~/.scm_breeze
    ~/.scm_breeze/install.sh
    git clone --depth=1 https://github.com/romkatv/powerlevel10k.git ~/powerlevel10k
    mkdir -p ~/command_history
    cat <<'    EOF' >> ~/.zshrc
        # Set history file in mountable location
        export HISTFILE=~/command_history/.zsh_history
        export HISTFILESIZE=10000000
        export HISTSIZE=10000000
        export SAVEHIST=10000000
        export HISTTIMEFORMAT="[%F %T] "
        setopt HIST_IGNORE_ALL_DUPS
        setopt EXTENDED_HISTORY
        setopt INC_APPEND_HISTORY
        setopt APPENDHISTORY

        source ~/powerlevel10k/powerlevel10k.zsh-theme
        [[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
        [ -s "$HOME/.scm_breeze/scm_breeze.sh" ] && source "$HOME/.scm_breeze/scm_breeze.sh"

        # Set up keybindings for word navigation using ctrl + left/right
        # The original key bindings are esc + b/f
        bindkey "^[[1;5C" forward-word
        bindkey "^[[1;5D" backward-word

        # Set up autocomplete for launch-job
		eval "$(register-python-argcomplete launch-job)"
    EOF
EOT

RUN --mount=type=cache,target=/root/.cache/pypoetry,sharing=locked \
    poetry install

## Relora
FROM deploy-singularity as relora
WORKDIR /workspaces/relora
COPY poetry.lock pyproject.toml .
# RUN pip uninstall -y nvidia-cusolver-cu12 nvidia-pyindex
# RUN pip install --force-reinstall packaging
RUN --mount=type=cache,target=/root/.cache/pypoetry,sharing=locked \
    poetry install

COPY . /workspaces/relora
