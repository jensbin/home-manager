{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    generators
    mkIf
    mkOption
    types
    ;

  cfg = config.services.mopidy;

  # The configuration format of Mopidy. It seems to use configparser with
  # some quirky handling of its types. You can see how they're handled in
  # `mopidy/config/types.py` from the source code.
  toMopidyConf = generators.toINI {
    mkKeyValue = generators.mkKeyValueDefault {
      mkValueString =
        v:
        if lib.isList v then
          "\n  " + lib.concatStringsSep "\n  " v
        else
          generators.mkValueStringDefault { } v;
    } " = ";
  };

  mopidyEnv = pkgs.buildEnv {
    name = "mopidy-with-extensions-${pkgs.mopidy.version}";
    paths = lib.closePropagation cfg.extensionPackages;
    pathsToLink = [ "/${pkgs.mopidyPackages.python.sitePackages}" ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    ignoreCollisions = true;
    postBuild = ''
      makeWrapper ${pkgs.mopidy}/bin/mopidy $out/bin/mopidy \
        --prefix PYTHONPATH : $out/${pkgs.mopidyPackages.python.sitePackages}
    '';
  };

  # Nix-representable format for Mopidy config.
  mopidyConfFormat =
    { }:
    {
      type =
        with types;
        let
          valueType =
            nullOr (oneOf [
              bool
              float
              int
              str
              (listOf valueType)
            ])
            // {
              description = "Mopidy config value";
            };
        in
        attrsOf (attrsOf valueType);

      generate = name: value: pkgs.writeText name (toMopidyConf value);
    };

  settingsFormat = mopidyConfFormat { };

  configFilePaths = lib.concatStringsSep ":" (
    [ "${config.xdg.configHome}/mopidy/mopidy.conf" ] ++ cfg.extraConfigFiles
  );

  hasMopidyLocal = builtins.elem pkgs.mopidy-local cfg.extensionPackages;

in
{
  meta.maintainers = [ lib.maintainers.foo-dogsquared ];

  options.services.mopidy = {
    enable = lib.mkEnableOption "Mopidy music player daemon";

    extensionPackages = mkOption {
      type = with types; listOf package;
      default = [ ];
      example = lib.literalExpression "with pkgs; [ mopidy-spotify mopidy-mpd mopidy-mpris ]";
      description = ''
        Mopidy extensions that should be loaded by the service.
      '';
    };

    settings = mkOption {
      type = settingsFormat.type;
      default = { };
      example = lib.literalExpression ''
        {
          file = {
            media_dirs = [
              "$XDG_MUSIC_DIR|Music"
              "~/library|Library"
            ];
            follow_symlinks = true;
            excluded_file_extensions = [
              ".html"
              ".zip"
              ".jpg"
              ".jpeg"
              ".png"
            ];
          };

          # Please don't put your mopidy-spotify configuration in the public. :)
          # Think of your Spotify Premium subscription!
          spotify = {
            client_id = "CLIENT_ID";
            client_secret = "CLIENT_SECRET";
          };
        }
      '';
      description = ''
        Configuration written to
        {file}`$XDG_CONFIG_HOME/mopidy/mopidy.conf`.

        See <https://docs.mopidy.com/en/latest/config/> for
        more details.
      '';
    };

    extraConfigFiles = mkOption {
      default = [ ];
      type = types.listOf types.path;
      description = ''
        Extra configuration files read by Mopidy when the service starts.
        Later files in the list override earlier configuration files and
        structured settings.
      '';
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      (lib.hm.assertions.assertPlatform "services.mopidy" pkgs lib.platforms.linux)
    ];

    xdg.configFile."mopidy/mopidy.conf".source =
      settingsFormat.generate "mopidy-${config.home.username}" cfg.settings;

    systemd.user.services.mopidy = {
      Unit = {
        Description = "mopidy music player daemon";
        Documentation = [ "https://mopidy.com/" ];
        After = [
          "network.target"
          "sound.target"
        ];
        X-Restart-Triggers = mkIf (cfg.settings != { }) [
          "${config.xdg.configFile."mopidy/mopidy.conf".source}"
        ];
      };

      Service = {
        ExecStart = "${mopidyEnv}/bin/mopidy --config ${configFilePaths}";
        Restart = "on-failure";
      };

      Install.WantedBy = [ "default.target" ];
    };

    systemd.user.services.mopidy-scan = mkIf hasMopidyLocal {
      Unit = {
        Description = "mopidy local files scanner";
        Documentation = [ "https://mopidy.com/" ];
        After = [
          "network.target"
          "sound.target"
        ];
      };

      Service = {
        ExecStart = "${mopidyEnv}/bin/mopidy --config ${configFilePaths} local scan";
        Type = "oneshot";
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
