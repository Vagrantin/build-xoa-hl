FROM hashicorp/packer:1.11.2
RUN packer plugins install -version 0.11.4 github.com/vatesfr/xenserver
