#version 430

struct Particle {
    vec2 pos;
    vec2 vel;
    float lifetime;
    float _padd;
};

layout(local_size_x = 32, local_size_y = 1, local_size_z = 1) in;

layout(std430, binding=0) buffer ssbo0 { Particle particles[]; };

//layout(location=0) uniform uint time;
layout(location=0) uniform float deltaTime;
layout(location=1) uniform vec2 source;

const float lifetime = 0.1;
const float velocity = 10;

void main() {
    Particle p = particles[gl_GlobalInvocationID.x];
    if (p.lifetime < 0) {
        p.lifetime = lifetime;
        p.pos = source;
        p.vel = normalize(p.vel);
    } else {
        p.pos += p.vel * deltaTime * velocity;
        p.lifetime -= deltaTime;
    }
    particles[gl_GlobalInvocationID.x] = p;
}
