# Jamal

Jamal is a lightweight tool to deploy static websites to remote web servers.

## Installation

```bash
gem install jamal
```

## Usage
1. Run `jamal init` to initialize the configuration file `_jamal.yml`.
2. Edit the `_jamal.yml` file to match your server configuration.
3. Run the `jamal setup` command to setup the server.
4. Run the `jamal deploy` command to deploy your website.

## Configuration

The `_jamal.yml` file is used to configure the server. It contains the following fields:

- `name`: The name of the website, this acts like an identifier for the website.
- `host`: The hostname of the server.
- `user`: The username of the server.
- `password`: The password of the server.
- `domains`: The domains of the website.
- `path`: The path to the website on your local machine.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.