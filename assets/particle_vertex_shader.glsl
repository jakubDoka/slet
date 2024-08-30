#version 430

struct Particle {
    vec2 pos;
    vec2 vel;
    float lifetime;
    float _padd;
};

layout (location=0) in vec2 vertexPosition;

layout(std430, binding=0) buffer ssbo0 { Particle positions[]; };

layout (location=0) uniform mat4 projectionMatrix;

out float lerp;

const float lifetime = 0.1;
const float size = 7;

void main() {
    Particle particle = positions[gl_InstanceID];
    lerp = (1 - pow(1 - (particle.lifetime / lifetime), 2));
    gl_Position = projectionMatrix * vec4(vertexPosition * lerp * size + particle.pos, 0.0, 1.0);
}
