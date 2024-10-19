angular.module("beamng.apps").directive("edcSettings", [
  "$http",
  "$rootScope",
  "$document",
  function ($http, $rootScope, $document) {
    const DEFAULT_PRESETS = [
      "Default",
      "Intense",
      "Smooth",
      "VR (Comfort)",
      "VR (Thrill)",
    ];
    const SORT_PRIORITY = {
      Default: 1,
      Intense: 2,
      Smooth: 3,
      "VR (Comfort)": 4,
      "VR (Thrill)": 5,
      Custom: 6,
      [undefined]: 7,
    };

    return {
      templateUrl: "/ui/modules/apps/edcSettings/app.html",
      replace: true,
      restrict: "EA",
      link: function (scope, element, attrs) {
        scope.expanded = true;
        scope.presetName = "";
        scope.isDefaultPreset = false;
        scope.loading = true;

        var units = {
          metric: { label: "km/h", mult: 3.6 },
          imperial: { label: "mph", mult: 2.23694 },
        };

        scope.distanceUnits = units.imperial;

        function saveSettings() {
          const data = {
            chosenPreset: scope.settings.chosenPreset,
            presets: {},
          };

          Object.entries(scope.settings.presets).forEach(([key, value]) => {
            if (DEFAULT_PRESETS.includes(key)) return;
            data.presets[key] = value;
          });

          bngApi.engineLua(
            `settings.setValue("edcSettings", ${bngApi.serializeToLua(data)})`
          );
        }

        function onSettingChanged() {
          scope.$evalAsync(function () {
            if (scope.settings.chosenPreset !== "Custom") {
              // Change chosenPreset to Custom
              if (!scope.settings.presets["Custom"]) {
                scope.settings.presets["Custom"] = Object.assign(
                  {},
                  scope.settings.presets[scope.settings.chosenPreset]
                );
              }
              scope.settings.chosenPreset = "Custom";
              updatePresetData();
            } else {
              scope.settings.presets["Custom"] = scope.presetData;
            }

            // Update speed values with correct distance units
            const custom = scope.settings.presets["Custom"];
            if (!custom) return;
            custom.speedShakeMinSpeed =
              scope.speedShakeMinSpeed / scope.distanceUnits.mult;
            custom.speedShakeMaxSpeed =
              scope.speedShakeMaxSpeed / scope.distanceUnits.mult;
            custom.fovMinSpeed = scope.fovMinSpeed / scope.distanceUnits.mult;
            custom.fovMaxSpeed = scope.fovMaxSpeed / scope.distanceUnits.mult;

            updateSpeedShake();
            updateFovSpeed();
            updatePresetNames();
            saveSettings();
          });
        }

        function updatePresetNames() {
          scope.presetNames = Object.keys(scope.settings.presets).sort(
            (a, b) => {
              const aVal = SORT_PRIORITY[a] || SORT_PRIORITY[undefined];
              const bVal = SORT_PRIORITY[b] || SORT_PRIORITY[undefined];
              return aVal - bVal;
            }
          );
        }

        function updateSpeedShake() {
          scope.speedShakeMinSpeed =
            scope.presetData.speedShakeMinSpeed * scope.distanceUnits.mult;
          scope.speedShakeMaxSpeed =
            scope.presetData.speedShakeMaxSpeed * scope.distanceUnits.mult;

          // Ensure min speed is always less than or equal to max and vice versa
          let unclampedMin = scope.speedShakeMinSpeed;
          scope.speedShakeMinSpeed = Math.min(
            scope.speedShakeMinSpeed,
            scope.speedShakeMaxSpeed
          );
          scope.speedShakeMaxSpeed = Math.max(
            unclampedMin,
            scope.speedShakeMaxSpeed
          );

          scope.speedShakeMinSpeedRounded = Math.round(
            scope.speedShakeMinSpeed
          );
          scope.speedShakeMaxSpeedRounded = Math.round(
            scope.speedShakeMaxSpeed
          );
        }

        function updateFovSpeed() {
          scope.fovMinSpeed =
            scope.presetData.fovMinSpeed * scope.distanceUnits.mult;
          scope.fovMaxSpeed =
            scope.presetData.fovMaxSpeed * scope.distanceUnits.mult;

          // Ensure min speed is always less than or equal to max and vice versa
          let unclampedMin = scope.fovMinSpeed;
          scope.fovMinSpeed = Math.min(scope.fovMinSpeed, scope.fovMaxSpeed);
          scope.fovMaxSpeed = Math.max(unclampedMin, scope.fovMaxSpeed);

          scope.fovMinSpeedRounded = Math.round(scope.fovMinSpeed);
          scope.fovMaxSpeedRounded = Math.round(scope.fovMaxSpeed);
        }

        function updatePresetData() {
          scope.presetData = Object.assign(
            {},
            scope.settings.presets[scope.settings.chosenPreset || "Default"]
          );
          updateSpeedShake();
          updateFovSpeed();
          scope.isDefaultPreset = DEFAULT_PRESETS.includes(
            scope.settings.chosenPreset
          );
        }

        function onPresetChanged() {
          updatePresetData();
          saveSettings();
        }

        function onCreatePreset() {
          scope.settings.presets[scope.presetName] =
            scope.settings.presets["Custom"];
          scope.settings.chosenPreset = scope.presetName;
          delete scope.settings.presets["Custom"];
          updatePresetData();
          updatePresetNames();
          saveSettings();
        }

        function onDeletePreset() {
          delete scope.settings.presets[scope.settings.chosenPreset];
          scope.settings.chosenPreset = "Default";
          scope.presetName = "";
          updatePresetData();
          updatePresetNames();
          saveSettings();
        }

        function saveLayout() {
          // $rootScope.$broadcast('appContainer:save');
        }

        scope.onPresetChanged = onPresetChanged;
        scope.onSettingChanged = onSettingChanged;
        scope.onCreatePreset = onCreatePreset;
        scope.onDeletePreset = onDeletePreset;
        scope.beginTranslate = function (event) {
          scope.translateStart(event);
          $document.on("mouseup", saveLayout);
        };

        scope.beginResize = function (event) {
          scope.resizeStart(event);
          $document.on("mouseup", saveLayout);
        };

        scope.closeApp = function () {
          scope.kill();
          saveLayout();
        };

        scope.$on("SettingsChanged", function (event, data) {
          scope.$evalAsync(function () {
            scope.distanceUnits = units[data.values.uiUnitLength];
            console.log(
              "distanceUnits: " + JSON.stringify(scope.distanceUnits)
            );
            updatePresetData();
          });
        });

        scope.resetSettings = function () {
          bngApi.engineLua('settings.setValue("edcMaxFov", 76)');
        };

        scope.showHide = function () {
          scope.expanded = !scope.expanded;
        };

        function init(defaultSettings) {
          scope.defaultSettings = defaultSettings;
          scope.loading = false;

          bngApi.engineLua('settings.getValue("edcSettings")', function (data) {
            if (!data) data = defaultSettings;

            DEFAULT_PRESETS.forEach((defPreset) => {
              data.presets[defPreset] = defaultSettings.presets[defPreset];
            });

            scope.settings = data;
            updatePresetData();
            updatePresetNames();
          });
        }

        $http
          .get("/settings/enhanceddriver/defaultSettings.json")
          .success(init)
          .error(() => {
            console.error(
              "Failed to load default settings. Enhanced Driver app will not work!"
            );
            scope.loadError = true;
          });
      },
    };
  },
]);
