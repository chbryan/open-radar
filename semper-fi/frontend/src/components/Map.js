// Existing map code
import MilitaryIcon from './icons/military.svg';  // Add icon

function MapComponent() {
  // Add military trails/icons
  return (
    <div>
      {/* Existing map */}
      <Layer type="military" icons={MilitaryIcon} trails={true} />
    </div>
  );
}
