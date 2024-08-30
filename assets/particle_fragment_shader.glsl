#version 430

in float lerp;
out vec4 finalColor;

void main() {
    finalColor = mix(vec4(0, 1, 0, 1),  vec4(1, 0, 0, 1), lerp);
}
